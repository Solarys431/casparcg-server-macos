/*
 * Copyright (c) 2011 Sveriges Television AB <info@casparcg.com>
 *
 * This file is part of CasparCG (www.casparcg.com).
 *
 * CasparCG is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * CasparCG is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with CasparCG. If not, see <http://www.gnu.org/licenses/>.
 *
 * Author: Niklas Andersson, niklas@niklaspandersson.se
 */

// The one place the Metal interop structs are needed; every other Vulkan translation unit is
// platform-neutral, so the define stays local to this file.
#define VK_USE_PLATFORM_METAL_EXT

#include "video_strategy.h"

#include "vulkan_frame_import.h"

#include <boost/format.hpp>
#include <boost/property_tree/ptree.hpp>

#include <common/env.h>
#include <common/log.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavutil/error.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
}

#import <Metal/Metal.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <IOSurface/IOSurfaceRef.h>

#include <cstdlib>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace caspar { namespace ffmpeg {

namespace {

/// VideoToolbox's deinterlacer. Metal compute rather than bwdif — FFmpeg has no
/// bwdif_videotoolbox, so interlaced material on macOS is deinterlaced to a different standard
/// than everywhere else. Deliberate: yadif on the hardware beats a software decode.
constexpr const char* deinterlacer = "yadif_videotoolbox";

using buffer_ref = std::shared_ptr<AVBufferRef>;

buffer_ref wrap_buffer_ref(AVBufferRef* ref)
{
    return buffer_ref(ref, [](AVBufferRef* p) { av_buffer_unref(&p); });
}

std::wstring error_text(int ret)
{
    char buf[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(ret, buf, sizeof(buf));
    return u16(std::string(buf));
}

/// For a stream with alpha FFmpeg asks VideoToolbox for AYUV ('y408') or AYUV64 ('y416'), and in
/// those VideoToolbox returns each chroma sample averaged with its left, upper and upper-left
/// neighbours: a half-pixel shift and a blur, up to 96/255 off on a one-pixel colour edge of ProRes
/// 4444, while luma and alpha are exact. Its 32BGRA output is exact, as is FFmpeg's software
/// decoder (measured on ProRes 4444 from both FFmpeg's and Apple's encoder; 4:2:0, 4:2:2 and 4:4:4
/// without alpha are exact in the formats FFmpeg picks for them). So for these streams make the
/// frames context in BGRA before FFmpeg makes one in AYUV. The cost is depth: 8 bits instead of
/// ProRes 4444's 12.
void request_exact_alpha_format(AVCodecContext* ctx)
{
    const auto* desc = av_pix_fmt_desc_get(ctx->sw_pix_fmt);
    if (!desc || !(desc->flags & AV_PIX_FMT_FLAG_ALPHA))
        return;

    AVBufferRef* frames = nullptr;
    if (avcodec_get_hw_frames_parameters(ctx, ctx->hw_device_ctx, AV_PIX_FMT_VIDEOTOOLBOX, &frames) < 0)
        return;
    reinterpret_cast<AVHWFramesContext*>(frames->data)->sw_format = AV_PIX_FMT_BGRA;
    if (av_hwframe_ctx_init(frames) < 0) {
        av_buffer_unref(&frames);
        return;
    }
    av_buffer_unref(&ctx->hw_frames_ctx);
    ctx->hw_frames_ctx = frames;
}

AVPixelFormat select_videotoolbox_format(AVCodecContext* ctx, const AVPixelFormat* formats)
{
    for (auto p = formats; *p != AV_PIX_FMT_NONE; ++p) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
            request_exact_alpha_format(ctx);
            return *p;
        }
    }
    // No VideoToolbox hwaccel for this stream after all — let the decoder pick its usual
    // software format; the producer notices the missing frames context and moves on.
    return avcodec_default_get_format(ctx, formats);
}

/// A mixer plane's sample layout, as the two APIs that have to agree on it spell the same thing.
/// The mixer's desc is the single source of truth: a plane is `stride` components of `depth`
/// bits, which is exactly what one texture of an IOSurface plane must be.
struct plane_format
{
    vk::Format     vulkan;
    MTLPixelFormat metal;
};

bool format_of_plane(const core::pixel_format_desc::plane& plane, plane_format& out)
{
    const bool sixteen = plane.depth != common::bit_depth::bit8;

    switch (plane.stride) {
        case 1:
            out = sixteen ? plane_format{vk::Format::eR16Unorm, MTLPixelFormatR16Unorm}
                          : plane_format{vk::Format::eR8Unorm, MTLPixelFormatR8Unorm};
            return true;
        case 2:
            out = sixteen ? plane_format{vk::Format::eR16G16Unorm, MTLPixelFormatRG16Unorm}
                          : plane_format{vk::Format::eR8G8Unorm, MTLPixelFormatRG8Unorm};
            return true;
        case 4:
            // ayuv64, VideoToolbox's ProRes 4444: A, Y, Cb, Cr in one plane.
            out = sixteen ? plane_format{vk::Format::eR16G16B16A16Unorm, MTLPixelFormatRGBA16Unorm}
                          : plane_format{vk::Format::eR8G8B8A8Unorm, MTLPixelFormatRGBA8Unorm};
            return true;
        default:
            return false;
    }
}

/// IOSurface's per-plane getters, for a packed surface too. One of those (ayuv64, ProRes 4444)
/// reports no planes at all, and its one plane is the whole surface.
size_t surface_plane_count(IOSurfaceRef surface)
{
    const auto planes = IOSurfaceGetPlaneCount(surface);
    return planes == 0 ? 1 : planes;
}

size_t surface_width(IOSurfaceRef surface, size_t plane)
{
    return IOSurfaceGetPlaneCount(surface) ? IOSurfaceGetWidthOfPlane(surface, plane) : IOSurfaceGetWidth(surface);
}

size_t surface_height(IOSurfaceRef surface, size_t plane)
{
    return IOSurfaceGetPlaneCount(surface) ? IOSurfaceGetHeightOfPlane(surface, plane) : IOSurfaceGetHeight(surface);
}

size_t surface_bytes_per_row(IOSurfaceRef surface, size_t plane)
{
    return IOSurfaceGetPlaneCount(surface) ? IOSurfaceGetBytesPerRowOfPlane(surface, plane)
                                           : IOSurfaceGetBytesPerRow(surface);
}

const void* surface_base_address(IOSurfaceRef surface, size_t plane)
{
    return IOSurfaceGetPlaneCount(surface) ? IOSurfaceGetBaseAddressOfPlane(surface, plane)
                                           : IOSurfaceGetBaseAddress(surface);
}

} // namespace

// ---------------------------------------------------------------------------------------

/// Decode with VideoToolbox, then let the mixer read the decoder's own frames.
///
/// The whole point is what does NOT happen: a VideoToolbox frame is a CVPixelBuffer backed by an
/// IOSurface, and the mixer reads it where the decoder wrote it. Nothing is copied by the CPU and
/// nothing crosses an API boundary; the only copy is the device-side one into mixer textures that
/// every hardware strategy ends with. Two routes, by what the Vulkan driver offers:
///
///   - VK_EXT_metal_objects (MoltenVK): each plane backs a Metal texture, which backs a VkImage.
///   - VK_EXT_external_memory_host (KosmicKrisp, which imports Metal memory only as a heap, so not
///     an IOSurface's texture): the surface's memory, which on Apple silicon is the very memory
///     the GPU reads, backs a VkBuffer, and the planes are copied out of it.
///
/// Two limits of MoltenVK shape the first route (verified on an M2 Pro, MoltenVK 1.4):
///
///   - Importing a planar IOSurface as one multi-planar VkImage does not work. MoltenVK routes
///     VkImportMetalIOSurfaceInfoEXT through its legacy vkUseIOSurfaceMVK, which compares the
///     whole surface's bytes-per-element against the image's block size and rejects the pair.
///     Hence one VkImage per plane, each backed by its own MTLTexture — which is what the mixer
///     wants anyway, one texture per plane.
///   - An imported image arrives in VK_IMAGE_LAYOUT_UNDEFINED, and transitioning out of that is
///     content-discarding per spec. It is not on MoltenVK, where layouts are near no-ops and the
///     memory is the IOSurface itself. This rests on that.
///
/// There is no synchronisation to do: VideoToolbox has finished with a frame before FFmpeg hands
/// it over, so unlike the Vulkan and CUDA strategies there is no timeline to wait or signal. What
/// must be respected instead is the other direction — the decoder may not recycle the surface
/// while our copy is still reading it — which is why the frame is handed to the import as a
/// keep-alive rather than released when make_frame returns.
class videotoolbox_video_strategy : public video_strategy
{
    const std::unique_ptr<vulkan_frame_import> import_;
    const buffer_ref                           device_;
    id<MTLDevice>                              metal_device_;
    const vk::Device                           vk_device_;

    /// true: the surface comes in as host memory behind a buffer; false: its planes as images.
    const bool                              host_buffer_;
    vk::DeviceSize                          host_alignment_          = 0;
    PFN_vkGetMemoryHostPointerPropertiesEXT host_pointer_properties_ = nullptr;

    /// One imported frame surface. VideoToolbox recycles a small pool of IOSurfaces for the whole
    /// of playback, so these are built once each and then simply looked up — without the cache
    /// this would create and destroy a VkImage per plane per frame.
    struct imported_surface
    {
        IOSurfaceRef                surface = nullptr; // retained
        std::vector<id<MTLTexture>> textures;          // retained
        std::vector<vk::Image>      images;            // ours to destroy
    };
    std::unordered_map<IOSurfaceRef, imported_surface> surfaces_;

    /// One surface's memory as a buffer, the host route. Built once per surface like the images,
    /// and built again only if the surface turns up mapped somewhere else.
    struct imported_buffer
    {
        IOSurfaceRef   surface = nullptr; // retained
        const void*    base    = nullptr; // the mapping the buffer was made from
        VkBuffer       buffer  = VK_NULL_HANDLE;
        VkDeviceMemory memory  = VK_NULL_HANDLE;
    };
    std::unordered_map<IOSurfaceRef, imported_buffer> buffers_;

    bool warned_unsupported_format_ = false;
    bool warned_import_failed_      = false;
    bool warned_outgrown_cache_     = false;

  public:
    videotoolbox_video_strategy(std::unique_ptr<vulkan_frame_import> import,
                                buffer_ref                           device,
                                id<MTLDevice>                        metal_device,
                                bool                                 host_buffer)
        : import_(std::move(import))
        , device_(std::move(device))
        , metal_device_([metal_device retain])
        , vk_device_(import_->vk_device())
        , host_buffer_(host_buffer)
    {
        if (host_buffer_) {
            vk::PhysicalDeviceExternalMemoryHostPropertiesEXT host_properties;
            vk::PhysicalDeviceProperties2                     properties;
            properties.pNext = &host_properties;
            import_->vk_physical_device().getProperties2(&properties);
            host_alignment_          = host_properties.minImportedHostPointerAlignment;
            host_pointer_properties_ = reinterpret_cast<PFN_vkGetMemoryHostPointerPropertiesEXT>(
                VULKAN_HPP_DEFAULT_DISPATCHER.vkGetDeviceProcAddr(static_cast<VkDevice>(vk_device_),
                                                                  "vkGetMemoryHostPointerPropertiesEXT"));
        }
    }

    ~videotoolbox_video_strategy() override
    {
        // Nothing may still be reading the images we are about to destroy. On a lost device the wait
        // fails at once, and a destructor must not throw.
        try {
            import_->drain();
        } catch (const vk::SystemError& e) {
            CASPAR_LOG(warning) << L"[ffmpeg] VideoToolbox strategy destroyed without its copies finishing: "
                                << u16(e.what());
        }

        for (auto& [surface, entry] : surfaces_)
            release(entry);
        for (auto& [surface, entry] : buffers_)
            release(entry);
        [metal_device_ release];
    }

    std::wstring name() const override { return L"videotoolbox"; }

    const AVCodec* preferred_decoder(AVCodecID id) const override
    {
        // FFmpeg ranks dav1d first for AV1, and it decodes in software only. Where VideoToolbox decodes
        // AV1 in hardware, FFmpeg's own av1 decoder is the one that drives it. Elsewhere, and on the CPU
        // strategy this producer falls back to, dav1d stays.
        if (id == AV_CODEC_ID_AV1 && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
            return avcodec_find_decoder_by_name("av1");
        return nullptr;
    }

    bool open_decoder(AVCodecContext& ctx, const AVCodec& codec) override
    {
        if (!supports_videotoolbox(codec))
            return false;

        // A new decoder is a new VideoToolbox session with a pool of its own: the surfaces of the
        // last one will not come back.
        forget_surfaces();

        ctx.hw_device_ctx = av_buffer_ref(device_.get());
        if (!ctx.hw_device_ctx)
            return false;

        ctx.get_format = select_videotoolbox_format;
        return true;
    }

    AVBufferRef* hw_device_context() const override { return device_.get(); }

    bool accepts(const AVFrame& frame) const override
    {
        // A software frame means get_format() declined VideoToolbox after all — either the codec
        // has no hwaccel for this stream, or the hwaccel failed to initialise and FFmpeg quietly
        // retried without it.
        if (frame.format != AV_PIX_FMT_VIDEOTOOLBOX || !frame.hw_frames_ctx)
            return false;

        const auto* frames_ctx = reinterpret_cast<const AVHWFramesContext*>(frame.hw_frames_ctx->data);
        if (!vulkan_frame_import::has_mixer_layout(frames_ctx->sw_format, frames_ctx->width, frames_ctx->height)) {
            // Formats the mixer has no plane layout for. The usual ones have one: 4:2:0, 4:2:2 and
            // 4:4:4 in either depth (nv12, p010, nv16, p210, nv24, p410, p416) and bgra for streams
            // with alpha (see request_exact_alpha_format).
            CASPAR_LOG(info) << L"[ffmpeg] The mixer has no layout for VideoToolbox frame format "
                             << u16(av_get_pix_fmt_name(frames_ctx->sw_format))
                             << L"; this file decodes on the CPU instead.";
            return false;
        }
        return true;
    }

    std::string deinterlace_filter(const std::string& deint) const override
    {
        return (boost::format("%s=mode=send_field:parity=auto:deint=%s") % deinterlacer % deint).str();
    }

    std::vector<AVPixelFormat> sink_formats() const override { return {AV_PIX_FMT_VIDEOTOOLBOX}; }

    core::draw_frame make_frame(void*                            tag,
                                std::shared_ptr<AVFrame>         video,
                                std::shared_ptr<AVFrame>         audio,
                                core::color_space                color_space,
                                core::frame_geometry::scale_mode scale_mode) override
    {
        if (!video || video->format != AV_PIX_FMT_VIDEOTOOLBOX || !video->hw_frames_ctx || !video->data[3]) {
            return import_->host_frame(tag, std::move(video), std::move(audio), color_space, scale_mode);
        }

        const auto* frames_ctx = reinterpret_cast<const AVHWFramesContext*>(video->hw_frames_ctx->data);

        // accepts() already refused any format without a layout, so this only guards a decoder
        // that changed format mid-stream.
        const auto layout =
            vulkan_frame_import::mixer_layout(frames_ctx->sw_format, video->width, video->height, color_space);
        if (!layout) {
            if (!warned_unsupported_format_) {
                warned_unsupported_format_ = true;
                CASPAR_LOG(warning) << L"[ffmpeg] VideoToolbox frame format changed to "
                                    << u16(av_get_pix_fmt_name(frames_ctx->sw_format))
                                    << L", which the mixer has no layout for; dropping video.";
            }
            return core::draw_frame{};
        }

        auto* pixel_buffer = reinterpret_cast<CVPixelBufferRef>(video->data[3]);
        if (host_buffer_)
            return make_buffer_frame(tag, pixel_buffer, *layout, std::move(video), audio, scale_mode);

        const auto* entry = import_surface(pixel_buffer, *layout);
        if (!entry)
            return import_failed();

        // Every image arrives in eUndefined: Metal wrote it, and Vulkan layouts do not describe
        // what another API did. See the class note on why that keeps the contents here.
        const std::vector<vk::ImageLayout> layouts(entry->images.size(), vk::ImageLayout::eUndefined);

        return import_->import_images(tag,
                                      entry->images,
                                      layouts,
                                      *layout,
                                      {}, // VideoToolbox is done with the frame before we see it
                                      audio,
                                      scale_mode,
                                      std::shared_ptr<void>(video));
    }

  private:
    /// The caches below only ever describe the small pool of surfaces one decoding session cycles
    /// through. A LOOP or a seek opens a new decoder on this same strategy, though, and the old
    /// session's surfaces never come back: kept, each would hold its memory and its imports for the
    /// producer's whole life. On KosmicKrisp every surface is also a device allocation, of which it
    /// allows 4096; looping clips used them up in half an hour and the device was lost. So a new
    /// decoder starts with empty caches, and a cache that outgrows any pool is emptied as well, in
    /// case a session ever changes its pool without a new decoder.
    static constexpr size_t max_cached_surfaces = 64;

    void forget_surfaces()
    {
        if (surfaces_.empty() && buffers_.empty())
            return;

        // Nothing may still be reading what is about to go.
        import_->drain();
        for (auto& [surface, entry] : surfaces_)
            release(entry);
        for (auto& [surface, entry] : buffers_)
            release(entry);
        surfaces_.clear();
        buffers_.clear();
    }

    void outgrown_cache()
    {
        if (!warned_outgrown_cache_) {
            warned_outgrown_cache_ = true;
            CASPAR_LOG(warning) << L"[ffmpeg] VideoToolbox handed out more than " << max_cached_surfaces
                                << L" surfaces in one session; emptying the import cache.";
        }
        forget_surfaces();
    }

    core::draw_frame import_failed()
    {
        if (!warned_import_failed_) {
            warned_import_failed_ = true;
            CASPAR_LOG(warning) << L"[ffmpeg] Could not import a VideoToolbox frame into Vulkan; dropping video.";
        }
        return core::draw_frame{};
    }

    /// The host route: the surface's memory as a buffer, its planes copied out of it by the GPU.
    core::draw_frame make_buffer_frame(void*                            tag,
                                       CVPixelBufferRef                 pixel_buffer,
                                       const core::pixel_format_desc&   desc,
                                       std::shared_ptr<AVFrame>         video,
                                       const std::shared_ptr<AVFrame>&  audio,
                                       core::frame_geometry::scale_mode scale_mode)
    {
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixel_buffer);
        if (!surface || surface_plane_count(surface) != desc.planes.size())
            return import_failed();

        // Locked for the mapping the buffer reads through. It is unlocked, and the frame handed back
        // to the decoder, when the copy out of it has retired.
        if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr) != kIOReturnSuccess)
            return import_failed();
        struct held
        {
            IOSurfaceRef             surface;
            std::shared_ptr<AVFrame> frame;
            held(IOSurfaceRef s, std::shared_ptr<AVFrame> f)
                : surface(s)
                , frame(std::move(f))
            {
            }
            held(const held&)            = delete;
            held& operator=(const held&) = delete;
            ~held() { IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr); }
        };
        auto keep = std::make_shared<held>(surface, std::move(video));

        const void* base  = IOSurfaceGetBaseAddress(surface);
        const auto* entry = import_buffer_of(surface, base);
        if (!entry)
            return import_failed();

        std::vector<vulkan_frame_import::buffer_plane> planes;
        for (size_t n = 0; n < desc.planes.size(); ++n) {
            const auto&  want   = desc.planes[n];
            const size_t texel  = static_cast<size_t>(want.stride) * (want.depth == common::bit_depth::bit8 ? 1 : 2);
            const size_t row    = surface_bytes_per_row(surface, n);
            const auto   offset = static_cast<const char*>(surface_base_address(surface, n)) -
                                static_cast<const char*>(base);
            if (static_cast<int>(surface_width(surface, n)) != want.width ||
                static_cast<int>(surface_height(surface, n)) != want.height || row % texel != 0 ||
                offset < 0 || static_cast<size_t>(offset) % texel != 0)
                return import_failed();
            planes.push_back({static_cast<vk::DeviceSize>(offset), static_cast<uint32_t>(row / texel)});
        }

        return import_->import_buffer(
            tag, vk::Buffer(entry->buffer), planes, desc, audio, scale_mode, std::shared_ptr<void>(keep));
    }

    /// The surface's memory as a VkBuffer (VK_EXT_external_memory_host), made once per surface and
    /// mapping. Null when the driver will not take it.
    const imported_buffer* import_buffer_of(IOSurfaceRef surface, const void* base)
    {
        if (const auto it = buffers_.find(surface); it != buffers_.end()) {
            if (it->second.base == base)
                return &it->second;
            // Mapped somewhere else since: nothing may still be reading through the old buffer.
            import_->drain();
            release(it->second);
            buffers_.erase(it);
        }

        if (!host_pointer_properties_ || host_alignment_ == 0 ||
            reinterpret_cast<uintptr_t>(base) % host_alignment_ != 0)
            return nullptr;

        if (buffers_.size() >= max_cached_surfaces)
            outgrown_cache();

        // The surface's last page is mapped whole, so rounding its size up stays inside that page.
        const VkDeviceSize size = (IOSurfaceGetAllocSize(surface) + host_alignment_ - 1) / host_alignment_ * host_alignment_;
        const auto&        d      = VULKAN_HPP_DEFAULT_DISPATCHER;
        const auto         device = static_cast<VkDevice>(vk_device_);

        imported_buffer entry;

        VkExternalMemoryBufferCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO};
        external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
        VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        info.pNext       = &external;
        info.size        = size;
        info.usage       = VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        if (d.vkCreateBuffer(device, &info, nullptr, &entry.buffer) != VK_SUCCESS)
            return nullptr;

        VkMemoryRequirements requirements{};
        d.vkGetBufferMemoryRequirements(device, entry.buffer, &requirements);
        VkMemoryHostPointerPropertiesEXT properties{VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
        const uint32_t types =
            host_pointer_properties_(device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT, base, &properties) ==
                    VK_SUCCESS
                ? requirements.memoryTypeBits & properties.memoryTypeBits
                : 0;
        if (types == 0) {
            release(entry);
            return nullptr;
        }

        VkImportMemoryHostPointerInfoEXT import{VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT};
        import.handleType   = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
        import.pHostPointer = const_cast<void*>(base);

        VkMemoryAllocateInfo allocate{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        allocate.pNext           = &import;
        allocate.allocationSize  = size;
        allocate.memoryTypeIndex = static_cast<uint32_t>(__builtin_ctz(types));
        if (d.vkAllocateMemory(device, &allocate, nullptr, &entry.memory) != VK_SUCCESS ||
            d.vkBindBufferMemory(device, entry.buffer, entry.memory, 0) != VK_SUCCESS) {
            release(entry);
            return nullptr;
        }

        CFRetain(surface);
        entry.surface = surface;
        entry.base    = base;
        return &buffers_.emplace(surface, entry).first->second;
    }

    void release(imported_buffer& entry)
    {
        const auto& d      = VULKAN_HPP_DEFAULT_DISPATCHER;
        const auto  device = static_cast<VkDevice>(vk_device_);
        if (entry.buffer)
            d.vkDestroyBuffer(device, entry.buffer, nullptr);
        if (entry.memory)
            d.vkFreeMemory(device, entry.memory, nullptr);
        if (entry.surface)
            CFRelease(entry.surface);
        entry = {};
    }

    static bool supports_videotoolbox(const AVCodec& codec)
    {
        for (int i = 0;; ++i) {
            const auto* config = avcodec_get_hw_config(&codec, i);
            if (!config)
                return false;
            if ((config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) &&
                config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX)
                return true;
        }
    }

    /// The frame's planes as VkImages, built on first sight of this IOSurface and reused for every
    /// later frame that comes back on it. Null when this surface cannot be imported at all.
    const imported_surface* import_surface(CVPixelBufferRef pixel_buffer, const core::pixel_format_desc& desc)
    {
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixel_buffer);
        if (!surface)
            return nullptr;

        if (const auto it = surfaces_.find(surface); it != surfaces_.end())
            return &it->second;

        const auto nb_planes = desc.planes.size();
        if (surface_plane_count(surface) != nb_planes)
            return nullptr;

        if (surfaces_.size() >= max_cached_surfaces)
            outgrown_cache();

        imported_surface entry;
        CFRetain(surface);
        entry.surface = surface;

        // A texture may only be shared with the CPU the way its surface is; on Apple silicon that
        // is one memory, on an Intel Mac the discrete case has to be managed.
        const MTLStorageMode storage = metal_device_.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;

        for (size_t plane = 0; plane < nb_planes; ++plane) {
            const auto& want = desc.planes[plane];

            plane_format format{};
            if (!format_of_plane(want, format)) {
                release(entry);
                return nullptr;
            }

            const auto width  = static_cast<int>(surface_width(surface, plane));
            const auto height = static_cast<int>(surface_height(surface, plane));
            if (width != want.width || height != want.height) {
                CASPAR_LOG(warning) << L"[ffmpeg] VideoToolbox plane " << plane << L" is " << width << L"x" << height
                                    << L" where the mixer expects " << want.width << L"x" << want.height
                                    << L"; not importing.";
                release(entry);
                return nullptr;
            }

            auto* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format.metal
                                                                                  width:width
                                                                                 height:height
                                                                              mipmapped:NO];
            descriptor.usage       = MTLTextureUsageShaderRead;
            descriptor.storageMode = storage;

            id<MTLTexture> texture = [metal_device_ newTextureWithDescriptor:descriptor
                                                                  iosurface:surface
                                                                      plane:plane];
            if (!texture) {
                release(entry);
                return nullptr;
            }
            entry.textures.push_back(texture); // +1 from newTextureWithDescriptor

            VkImportMetalTextureInfoEXT metal{VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT};
            // A single-plane image: VK_EXT_metal_objects wants PLANE_0 for one, not COLOR
            // (VUID-VkImageCreateInfo-pNext-06784).
            metal.plane      = VK_IMAGE_ASPECT_PLANE_0_BIT;
            metal.mtlTexture = texture;

            vk::ImageCreateInfo info;
            info.pNext         = &metal;
            info.imageType     = vk::ImageType::e2D;
            info.format        = format.vulkan;
            info.extent        = vk::Extent3D(static_cast<uint32_t>(width), static_cast<uint32_t>(height), 1);
            info.mipLevels     = 1;
            info.arrayLayers   = 1;
            info.samples       = vk::SampleCountFlagBits::e1;
            info.tiling        = vk::ImageTiling::eOptimal;
            info.usage         = vk::ImageUsageFlagBits::eTransferSrc | vk::ImageUsageFlagBits::eSampled;
            info.sharingMode   = vk::SharingMode::eExclusive;
            info.initialLayout = vk::ImageLayout::eUndefined;

            // No memory is bound and none may be: the image's storage IS the imported texture's.
            vk::Image image;
            if (vk_device_.createImage(&info, nullptr, &image) != vk::Result::eSuccess) {
                release(entry);
                return nullptr;
            }
            entry.images.push_back(image);
        }

        return &surfaces_.emplace(surface, std::move(entry)).first->second;
    }

    void release(imported_surface& entry)
    {
        for (auto image : entry.images)
            vk_device_.destroyImage(image);
        for (id<MTLTexture> texture : entry.textures)
            [texture release];
        if (entry.surface)
            CFRelease(entry.surface);
        entry = {};
    }
};

std::shared_ptr<video_strategy>
try_create_videotoolbox_video_strategy(const std::shared_ptr<core::frame_factory>& frame_factory)
{
    const auto deint =
        env::properties().get<std::wstring>(L"configuration.ffmpeg.producer.auto-deinterlace", L"interlaced");
    if (deint != L"none" && !avfilter_get_by_name(deinterlacer)) {
        CASPAR_LOG(debug) << L"[ffmpeg] This FFmpeg build has no " << u16(deinterlacer)
                          << L" filter, so VideoToolbox decoding cannot deinterlace; not offering it.";
        return nullptr;
    }

    // Import-only: VideoToolbox decodes into its own surfaces, so FFmpeg is never told about our
    // Vulkan device. That is what makes this work at all on macOS, where FFmpeg ships with the
    // VideoToolbox hardware device type and no Vulkan one.
    auto import = vulkan_frame_import::create_for_import(frame_factory);
    if (!import)
        return nullptr;

    // Without one of these there is no way to give Vulkan the decoder's memory, and a copy through
    // the host would be a different strategy, not this one. The image route wins where the driver
    // has it. CASPARCG_VT_IMPORT=host_buffer forces the other one, to test it on MoltenVK.
    const bool  metal_objects = import->has_device_extension(VK_EXT_METAL_OBJECTS_EXTENSION_NAME);
    const bool  host_memory   = import->has_device_extension(VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME);
    const char* forced        = std::getenv("CASPARCG_VT_IMPORT");
    const bool  host_buffer   = host_memory && (!metal_objects || (forced && std::string(forced) == "host_buffer"));
    if (!metal_objects && !host_buffer) {
        CASPAR_LOG(debug) << L"[ffmpeg] The Vulkan device has neither VK_EXT_metal_objects nor "
                             L"VK_EXT_external_memory_host; VideoToolbox decoding unavailable.";
        return nullptr;
    }

    id<MTLDevice> metal_device = MTLCreateSystemDefaultDevice();
    if (!metal_device) {
        CASPAR_LOG(debug) << L"[ffmpeg] No Metal device; VideoToolbox decoding unavailable.";
        return nullptr;
    }

    AVBufferRef* device = nullptr;
    const auto   ret = av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0);
    if (ret < 0) {
        CASPAR_LOG(debug) << L"[ffmpeg] No VideoToolbox device (" << error_text(ret)
                          << L"); hardware decoding unavailable.";
        [metal_device release];
        return nullptr;
    }

    CASPAR_LOG(info) << L"[ffmpeg] VideoToolbox decoding available, importing into the accelerator device through "
                     << (host_buffer ? L"VK_EXT_external_memory_host." : L"VK_EXT_metal_objects.");
    auto strategy = std::make_shared<videotoolbox_video_strategy>(
        std::move(import), wrap_buffer_ref(device), metal_device, host_buffer);

    // MTLCreateSystemDefaultDevice returned it owned, and the strategy took its own reference.
    [metal_device release];
    return strategy;
}

}} // namespace caspar::ffmpeg
