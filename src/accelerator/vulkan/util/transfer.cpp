/*
 * Copyright 2025
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

#include "transfer.h"

#include "barrier.h"
#include "buffer.h"
#include "command_context.h"
#include "device.h"
#include "handoff.h"
#include "texture.h"
#include "vulkan_queue.h"

#include <common/future.h>
#include <common/log.h>

#include <tbb/parallel_for.h>

#include <cstdint>
#include <cstring>

namespace caspar { namespace accelerator { namespace vulkan {

namespace {

// Three-channel formats are optional in Vulkan and Metal has none: KosmicKrisp crashes creating
// the R8G8B8 image that every 24-bit PNG or JPEG asked for. OpenGL drivers expand RGB on upload,
// which is why the OpenGL mixer never saw this; do the same here, with an opaque alpha. The
// shader's rgb and bgr cases read only the first three channels, so they need no change.
template <typename T>
void expand_to_four_channels(const T* from, T* to, std::size_t pixels, T opaque)
{
    tbb::parallel_for(tbb::blocked_range<std::size_t>(0, pixels, 1 << 15),
                      [&](const tbb::blocked_range<std::size_t>& range) {
                          for (auto i = range.begin(); i != range.end(); ++i) {
                              to[i * 4 + 0] = from[i * 3 + 0];
                              to[i * 4 + 1] = from[i * 3 + 1];
                              to[i * 4 + 2] = from[i * 3 + 2];
                              to[i * 4 + 3] = opaque;
                          }
                      });
}

} // namespace

transfer::transfer(device& device)
    : device_(device)
    , transfer_queue_(device.acquire_queue(queue_type::transfer))
    , render_queue_(device.queue())
    , ctx_(std::make_unique<command_context>(device.getVkDevice(), transfer_queue_))
{
}

transfer::~transfer() {}

std::shared_ptr<texture>
transfer::copy_async(const array<const uint8_t>& source, int width, int height, int stride, common::bit_depth depth)
{
    std::shared_ptr<buffer> buf;

    if (stride == 3) {
        const auto pixels = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
        if (depth == common::bit_depth::bit8) {
            buf = device_.create_buffer(static_cast<int>(pixels * 4), true);
            expand_to_four_channels(source.data(), static_cast<std::uint8_t*>(buf->data()), pixels, std::uint8_t{0xFF});
        } else {
            buf = device_.create_buffer(static_cast<int>(pixels * 4 * sizeof(std::uint16_t)), true);
            expand_to_four_channels(reinterpret_cast<const std::uint16_t*>(source.data()),
                                    static_cast<std::uint16_t*>(buf->data()),
                                    pixels,
                                    std::uint16_t{0xFFFF});
        }
        stride = 4;
    } else if (auto tmp = source.storage<std::shared_ptr<buffer>>()) {
        buf = *tmp;
    } else {
        buf = device_.create_buffer(static_cast<int>(source.size()), true);
        std::memcpy(buf->data(), source.data(), source.size());
    }

    auto tex = device_.create_texture(width, height, stride, depth);

    vk::BufferImageCopy region(0,
                               0,
                               0,
                               vk::ImageSubresourceLayers(vk::ImageAspectFlagBits::eColor, 0, 0, 1),
                               vk::Offset3D(0, 0, 0),
                               vk::Extent3D(width, height, 1));

    // Hand the uploaded texture off to the render queue: the upload's final
    // transition to shader-read becomes the producer (release) half. At distance 0
    // this is exactly the plain transition it was before; at distance 1/2 the
    // renderer waits the completion (and at 2 records the matching acquire) — see
    // renderpass::commit, which consumes the stamped pending-handoff.
    auto handoff = make_handoff(*transfer_queue_,
                                *render_queue_,
                                vk::ImageLayout::eTransferDstOptimal,
                                vk::ImageLayout::eShaderReadOnlyOptimal,
                                vk::PipelineStageFlagBits2::eTransfer,
                                vk::AccessFlagBits2::eTransferWrite,
                                vk::PipelineStageFlagBits2::eFragmentShader,
                                vk::AccessFlagBits2::eShaderRead);

    auto token = ctx_->record_and_submit([&](vk::CommandBuffer cmd) {
        // After the earlier transfers on this queue: the pooled texture may come from a frame that
        // was let go before it was drawn, with its copy still on the GPU (see gpu_producer::produce).
        transitionImageLayout(tex->id(),
                              vk::ImageLayout::eUndefined,
                              vk::AccessFlagBits2::eTransferWrite,
                              vk::PipelineStageFlagBits2::eTransfer,

                              vk::ImageLayout::eTransferDstOptimal,
                              vk::AccessFlagBits2::eTransferWrite,
                              vk::PipelineStageFlagBits2::eTransfer,
                              cmd);

        cmd.copyBufferToImage(buf->id(), tex->id(), vk::ImageLayout::eTransferDstOptimal, region);

        record_release(cmd, handoff, tex->id());
    });

    handoff.completion = token;
    tex->set_pending_handoff(handoff);

    // The GPU reads buf some time after this returns, and a buffer back in its pool can be handed
    // to the next upload of the same size and overwritten first. Keep it for as long as the texture
    // made from it, which is drawn only after the copy has run.
    auto ptr = tex.get();
    return std::shared_ptr<texture>(ptr, [tex = std::move(tex), buf = std::move(buf)](texture*) mutable {});
}

handoff_token transfer::readback_handoff() const
{
    // The render queue is the producer (it last wrote `target` as a color attachment
    // in eRenderingLocalRead); the transfer queue is the consumer that reads it back
    // as a transfer source. Mirror of the upload hand-off in copy_async(upload).
    return make_handoff(*render_queue_,
                        *transfer_queue_,
                        vk::ImageLayout::eRenderingLocalRead,
                        vk::ImageLayout::eTransferSrcOptimal,
                        vk::PipelineStageFlagBits2::eColorAttachmentOutput,
                        vk::AccessFlagBits2::eColorAttachmentWrite,
                        vk::PipelineStageFlagBits2::eTransfer,
                        vk::AccessFlagBits2::eTransferRead);
}

std::future<array<const uint8_t>> transfer::copy_async(const std::shared_ptr<texture>& source,
                                                       const handoff_token&            from_renderer)
{
    auto buf = device_.create_buffer(source->size(), false);

    vk::CopyImageToBufferInfo2 copyInfo{};
    copyInfo.dstBuffer      = buf->id();
    copyInfo.srcImage       = source->id();
    copyInfo.srcImageLayout = vk::ImageLayout::eTransferSrcOptimal;

    vk::BufferImageCopy2 region{};
    region.bufferOffset     = 0;
    region.imageSubresource = vk::ImageSubresourceLayers(vk::ImageAspectFlagBits::eColor, 0, 0, 1);
    region.imageOffset      = vk::Offset3D{0, 0, 0};
    region.imageExtent =
        vk::Extent3D{static_cast<uint32_t>(source->width()), static_cast<uint32_t>(source->height()), 1};
    copyInfo.setRegions(region);

    // Hand the read-back target back to the render queue: after the copy the image
    // returns to the shader-read output invariant (TRANSFER_SRC -> SHADER_READ) so a
    // GPU-direct consumer can still sample it off the const_frame. The caller's
    // finalize consumes this (waits the completion + records the acquire half).
    auto to_renderer = make_handoff(*transfer_queue_,
                                    *render_queue_,
                                    vk::ImageLayout::eTransferSrcOptimal,
                                    vk::ImageLayout::eShaderReadOnlyOptimal,
                                    vk::PipelineStageFlagBits2::eTransfer,
                                    vk::AccessFlagBits2::eTransferRead,
                                    vk::PipelineStageFlagBits2::eFragmentShader,
                                    vk::AccessFlagBits2::eShaderRead);

    auto token = ctx_->record_and_submit(
        [&](vk::CommandBuffer cmd) {
            // Acquire half of the render->transfer hand-off (no-op below distance 2;
            // at distance 2 it completes the eRenderingLocalRead -> eTransferSrcOptimal
            // transition and takes ownership). At distance 0/1 the render-side release
            // already moved the layout, so the image is eTransferSrcOptimal regardless.
            acquire_into(cmd, from_renderer, source->id());

            cmd.copyImageToBuffer2(copyInfo);

            // TODO: sequential transfer-src -> shader-read on one image. Concurrent
            // host + GPU-direct consumers at distance 2 will need a scratch copy so
            // the readback and the sampler do not serialize.
            record_release(cmd, to_renderer, source->id());
        },
        from_renderer.completion);

    to_renderer.completion = token;
    source->set_pending_handoff(to_renderer);

    return std::async(std::launch::deferred, [this, buf = std::move(buf), token]() mutable {
        // Until the copy is done, as the OpenGL mixer waits: after a timeout this handed the
        // consumers a frame the GPU had not finished writing.
        if (!ctx_->wait(token)) {
            CASPAR_LOG(warning) << L"[Vulkan] A readback has been on the GPU for more than a second";
            ctx_->wait(token, UINT64_MAX);
        }

        auto ptr  = reinterpret_cast<uint8_t*>(buf->data());
        auto size = buf->size();
        return array<const uint8_t>(ptr, size, std::move(buf));
    });
}

}}} // namespace caspar::accelerator::vulkan
