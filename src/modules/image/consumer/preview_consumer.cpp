/*
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
 */

#include "preview_consumer.h"

#include <common/except.h>
#include <common/future.h>
#include <common/log.h>
#include <common/utf.h>

#include <core/consumer/channel_info.h>
#include <core/frame/frame.h>
#include <core/frame/pixel_format.h>
#include <core/video_format.h>

#include <boost/algorithm/string.hpp>
#include <boost/property_tree/ptree.hpp>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <map>
#include <mutex>
#include <string>

#ifndef _WIN32
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

namespace caspar::image {

namespace {

// The shared memory, version 2: a header of `header_bytes` (1024), then `slots` pictures of `stride * height` bytes,
// BGRA, premultiplied like the mixer's output. The writer fills slot (sequence + 1) % slots, then publishes
// sequence + 1; a reader takes slot sequence % slots and checks afterwards that sequence did not move on by
// `slots - 1`: with three slots and a frame every 20 ms at most, a copy of a few hundred kilobytes always finishes
// first.
//
// Loudness (EBU R 128, ITU-R BS.1770): the first two audio channels, K-weighted, in blocks of 100 ms. Block n is the
// mean square of the weighted signal, summed over the two channels, in power[n % 128]; `blocks` counts the blocks
// written so far. A reader that falls behind by less than 12.8 s loses none: momentary loudness is the mean of the
// last 4 blocks, short-term of the last 30, and the gated 400 ms blocks of the integrated loudness are 4 in a row.
// Peaks are the highest sample of each channel since the previous picture, over both fields of an interlaced frame.
//
// The server only writes this memory and never reads anything back from it: any process of the same user can open
// it, so sizes and counters live in the consumer, and the header is a copy for the reader.
struct preview_header
{
    char                       magic[8]; // "VTXPVW1"
    std::uint32_t              version;  // 2
    std::uint32_t              width;
    std::uint32_t              height;
    std::uint32_t              stride;
    std::uint32_t              slots;
    std::uint32_t              channel;
    std::uint32_t              fps_num;
    std::uint32_t              fps_den;
    std::uint32_t              audio_channels;
    std::uint32_t              header_bytes; // where the pictures start (version 1 had 0 here, and 256 bytes)
    std::atomic<std::uint64_t> sequence;
    std::uint64_t              frame_number;
    std::int64_t               timestamp_ns; // steady clock, nanoseconds
    float                      peaks[16];    // per audio channel, 0..1 of full scale, since the previous picture
    std::uint32_t              audio_rate;    // samples per second
    std::uint32_t              block_samples; // samples per channel in a loudness block (100 ms)
    std::atomic<std::uint64_t> blocks;        // loudness blocks written so far
    float                      power[128];    // ring of block powers, see above
    std::uint8_t               padding[1024 - 136 - 8 - 8 - 128 * 4];
};
static_assert(sizeof(preview_header) == 1024, "the preview header is 1024 bytes");
static_assert(offsetof(preview_header, sequence) == 48 && offsetof(preview_header, peaks) == 72 &&
                  offsetof(preview_header, audio_rate) == 136 && offsetof(preview_header, blocks) == 144 &&
                  offsetof(preview_header, power) == 152,
              "the preview header layout is part of the contract with the client");

constexpr std::uint32_t preview_width  = 640;
constexpr std::uint32_t preview_slots  = 3;
constexpr std::uint32_t loudness_ring  = 128;
constexpr double        pi             = 3.14159265358979323846;

// A biquad, transposed direct form II, in double precision.
struct biquad
{
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;

    double process(double x)
    {
        const double y = b0 * x + z1;
        z1             = b1 * x - a1 * y + z2;
        z2             = b2 * x - a2 * y;
        return y;
    }
};

// The K-weighting of ITU-R BS.1770: a high shelf (PRE) and a high pass (RLB), for any sample rate, with the
// parametrization FFmpeg uses in libavfilter/f_ebur128.c (8.1.3), which gives the BS.1770 coefficients at 48 kHz.
struct k_weighting
{
    biquad pre, rlb;

    explicit k_weighting(double rate = 48000)
    {
        double       f0 = 1681.974450955533;
        double       G  = 3.999843853973347;
        double       Q  = 0.7071752369554196;
        double       K  = std::tan(pi * f0 / rate);
        const double Vh = std::pow(10.0, G / 20.0);
        const double Vb = std::pow(Vh, 0.4996667741545416);
        const double a0 = 1.0 + K / Q + K * K;
        pre.b0          = (Vh + Vb * K / Q + K * K) / a0;
        pre.b1          = 2.0 * (K * K - Vh) / a0;
        pre.b2          = (Vh - Vb * K / Q + K * K) / a0;
        pre.a1          = 2.0 * (K * K - 1.0) / a0;
        pre.a2          = (1.0 - K / Q + K * K) / a0;
        f0              = 38.13547087602444;
        Q               = 0.5003270373238773;
        K               = std::tan(pi * f0 / rate);
        rlb.b0          = 1.0;
        rlb.b1          = -2.0;
        rlb.b2          = 1.0;
        rlb.a1          = 2.0 * (K * K - 1.0) / (1.0 + K / Q + K * K);
        rlb.a2          = (1.0 - K / Q + K * K) / (1.0 + K / Q + K * K);
    }

    double process(double x) { return rlb.process(pre.process(x)); }
};

// Every preview lives under this prefix, so that a name, which can come from an AMCP client, reaches nothing but other
// previews.
std::string object_name(const std::string& name)
{
    return name.rfind("vtx-pv-", 0) == 0 ? "/" + name : "/vtx-pv-" + name;
}

void check_name(const std::string& name)
{
    const auto allowed = [](char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' ||
               c == '.';
    };
    // macOS allows 31 characters, the leading slash included.
    if (object_name(name).size() > 31 || !std::all_of(name.begin(), name.end(), allowed))
        CASPAR_THROW_EXCEPTION(invalid_argument() << msg_info("preview name: too long, or not a-z A-Z 0-9 - _ ."));
}

// Which consumer holds each name in this server. Consumers are destroyed on a thread of their own, so the one being
// replaced can end after its successor has started: it must not take the name away. Never freed, as a consumer can
// still be ending while the process exits.
std::mutex& holders_mutex()
{
    static auto* mutex = new std::mutex;
    return *mutex;
}

std::map<std::string, const void*>& holders()
{
    static auto* map = new std::map<std::string, const void*>;
    return *map;
}

struct preview_consumer : public core::frame_consumer
{
    const std::string   name_;
    int                 channel_index_ = 0;
    core::video_format_desc format_desc_;
    common::bit_depth   depth_         = common::bit_depth::bit8;
    void*               memory_        = nullptr;
    std::size_t         size_          = 0;
    std::string         shm_name_;     // set only once this consumer has created the object
    std::uint64_t       frames_        = 0;
    std::uint32_t       header_bytes_  = sizeof(preview_header);
    std::uint32_t       height_        = 0;
    std::uint32_t       stride_        = 0;
    std::uint64_t       sequence_      = 0;
    // Loudness and peaks, accumulated over every field until they are published.
    k_weighting         weighting_[2];
    double              block_sum_     = 0;
    std::uint32_t       block_count_   = 0;
    std::uint32_t       block_samples_ = 4800;
    std::uint64_t       blocks_        = 0;
    std::int64_t        peak_[16]      = {};

    explicit preview_consumer(std::string name)
        : name_(std::move(name))
    {
    }

    ~preview_consumer() override { close(); }

    void close()
    {
#ifndef _WIN32
        if (memory_ != nullptr) {
            munmap(memory_, size_);
            memory_ = nullptr;
        }
        if (!shm_name_.empty()) {
            std::lock_guard<std::mutex> lock(holders_mutex());
            const auto                  holder = holders().find(shm_name_);
            if (holder != holders().end() && holder->second == this) {
                holders().erase(holder);
                shm_unlink(shm_name_.c_str());
            }
            shm_name_.clear();
        }
#endif
    }

#ifndef _WIN32
    // The object of that name, new and mapped, or nullptr. Only this user may open it (0600). Under the prefix there
    // can only be a preview of this server, which it replaces, or what a crashed one left: either goes first.
    void* create_memory(const std::string& name)
    {
        std::lock_guard<std::mutex> lock(holders_mutex());
        holders()[name] = this;
        shm_unlink(name.c_str());

        const char* failed = nullptr;
        int         error  = 0;
        void*       memory = MAP_FAILED;
        const int   fd     = shm_open(name.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd < 0) {
            failed = "shm_open";
            error  = errno;
        } else if (ftruncate(fd, static_cast<off_t>(size_)) != 0) {
            failed = "ftruncate";
            error  = errno;
        } else {
            memory = mmap(nullptr, size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (memory == MAP_FAILED) {
                failed = "mmap";
                error  = errno;
            }
        }
        if (fd >= 0)
            ::close(fd);
        if (failed == nullptr)
            return memory;

        if (fd >= 0)
            shm_unlink(name.c_str());
        holders().erase(name);
        CASPAR_LOG(warning) << L"[preview] " << u16(failed) << L" " << u16(name) << L": " << u16(std::strerror(error));
        return nullptr;
    }
#endif

    void initialize(const core::video_format_desc& format_desc,
                    const core::channel_info&      channel_info,
                    int /*port_index*/) override
    {
        format_desc_   = format_desc;
        channel_index_ = channel_info.index;
        depth_         = channel_info.depth;
#ifndef _WIN32
        close();
        auto name = object_name(name_.empty() ? std::to_string(channel_index_) : name_);
        height_   = static_cast<std::uint32_t>(
            std::lround(static_cast<double>(preview_width) * format_desc.height / std::max(1, format_desc.width)));
        stride_   = preview_width * 4;
        size_     = header_bytes_ + static_cast<std::size_t>(stride_) * height_ * preview_slots;
        sequence_ = 0;
        memory_   = create_memory(name);
        if (memory_ == nullptr)
            return;
        shm_name_.swap(name);
        std::memset(memory_, 0, sizeof(preview_header));
        auto* h = static_cast<preview_header*>(memory_);
        std::memcpy(h->magic, "VTXPVW1", 8);
        h->version        = 2;
        h->header_bytes   = header_bytes_;
        h->width          = preview_width;
        h->height         = height_;
        h->stride         = stride_;
        h->slots          = preview_slots;
        h->channel        = static_cast<std::uint32_t>(channel_index_);
        h->fps_num        = static_cast<std::uint32_t>(format_desc.framerate.numerator());
        h->fps_den        = static_cast<std::uint32_t>(format_desc.framerate.denominator());
        h->audio_channels = static_cast<std::uint32_t>(std::min(16, format_desc.audio_channels));
        const int rate    = format_desc.audio_sample_rate > 0 ? format_desc.audio_sample_rate : 48000;
        for (auto& w : weighting_)
            w = k_weighting(rate);
        block_samples_    = static_cast<std::uint32_t>(rate / 10);
        block_sum_        = 0;
        block_count_      = 0;
        blocks_           = 0;
        std::fill(std::begin(peak_), std::end(peak_), 0);
        h->audio_rate     = static_cast<std::uint32_t>(rate);
        h->block_samples  = block_samples_;
        h->blocks.store(0, std::memory_order_release);
        h->sequence.store(0, std::memory_order_release);
        CASPAR_LOG(info) << print() << L" " << preview_width << L"x" << height_ << L" in " << u16(shm_name_);
#endif
    }

    std::future<bool> send(core::video_field field, core::const_frame frame) override
    {
        if (memory_ == nullptr)
            return make_ready_future(true);
        auto* h = static_cast<preview_header*>(memory_);

        // The audio of every field: an interlaced channel sends two frames per picture, each with its own samples.
        const auto& audio    = frame.audio_data();
        const int   channels = std::max(1, format_desc_.audio_channels);
        const int   measured = std::min(2, channels);
        const auto  samples  = audio.size() / static_cast<std::size_t>(channels);
        const auto* data     = audio.data();
        for (std::size_t s = 0; s < samples; ++s) {
            const auto* sample = data + s * channels;
            for (int c = 0; c < std::min(16, channels); ++c)
                peak_[c] = std::max<std::int64_t>(peak_[c], std::llabs(static_cast<std::int64_t>(sample[c])));
            double sum = 0;
            for (int c = 0; c < measured; ++c) {
                const double y = weighting_[c].process(static_cast<double>(sample[c]) / 2147483648.0);
                sum += y * y;
            }
            block_sum_ += sum;
            if (++block_count_ == block_samples_) {
                h->power[blocks_ % loudness_ring] = static_cast<float>(block_sum_ / block_samples_);
                h->blocks.store(++blocks_, std::memory_order_release);
                block_sum_   = 0;
                block_count_ = 0;
            }
        }

        // One picture per frame: on an interlaced channel the second field is the same picture.
        if (field == core::video_field::b)
            return make_ready_future(true);
        auto*       slot   = static_cast<std::uint8_t*>(memory_) + header_bytes_ +
                      static_cast<std::size_t>(stride_) * height_ * ((sequence_ + 1) % preview_slots);
        const auto& image  = frame.image_data(0);
        const int   w      = static_cast<int>(frame.width());
        const int   hh     = static_cast<int>(frame.height());
        const int   bpp    = depth_ == common::bit_depth::bit8 ? 4 : 8;
        if (image.size() >= static_cast<std::size_t>(w) * hh * bpp && w > 1 && hh > 1) {
            const auto* src = image.data();
            const double sx = static_cast<double>(w) / preview_width;
            const double sy = static_cast<double>(hh) / height_;
            const int    hi = bpp == 8 ? 1 : 0; // 16-bit: the high byte of each little-endian component
            for (std::uint32_t y = 0; y < height_; ++y) {
                const int y0 = std::min(hh - 2, static_cast<int>(y * sy));
                auto*     d  = slot + static_cast<std::size_t>(y) * stride_;
                for (std::uint32_t x = 0; x < preview_width; ++x) {
                    const int x0 = std::min(w - 2, static_cast<int>(x * sx));
                    // The mean of a 2x2 block: cheap, and smoother than a single sample.
                    const auto* p00 = src + (static_cast<std::size_t>(y0) * w + x0) * bpp;
                    const auto* p01 = p00 + bpp;
                    const auto* p10 = p00 + static_cast<std::size_t>(w) * bpp;
                    const auto* p11 = p10 + bpp;
                    for (int c = 0; c < 4; ++c) {
                        const int o = c * (bpp / 4) + hi;
                        d[x * 4 + c] = static_cast<std::uint8_t>((p00[o] + p01[o] + p10[o] + p11[o] + 2) / 4);
                    }
                }
            }
        }
        // The peaks since the previous picture, of full scale.
        for (int c = 0; c < 16; ++c) {
            h->peaks[c] = static_cast<float>(static_cast<double>(peak_[c]) / 2147483648.0);
            peak_[c]    = 0;
        }
        h->frame_number = ++frames_;
        h->timestamp_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                              std::chrono::steady_clock::now().time_since_epoch())
                              .count();
        h->sequence.store(++sequence_, std::memory_order_release);
        return make_ready_future(true);
    }

    std::wstring print() const override { return L"preview[" + std::to_wstring(channel_index_) + L"]"; }
    std::wstring name() const override { return L"preview"; }
    int          index() const override { return 1100 + channel_index_; }

    core::monitor::state state() const override
    {
        core::monitor::state state;
        state["preview/name"] = shm_name_;
        return state;
    }
};

} // namespace

spl::shared_ptr<core::frame_consumer>
create_preview_consumer(const std::vector<std::wstring>& params,
                        const core::video_format_repository& /*format_repository*/,
                        const std::vector<spl::shared_ptr<core::video_channel>>& /*channels*/,
                        const core::channel_info& /*channel_info*/)
{
    if (params.empty() || !boost::iequals(params.at(0), L"PREVIEW"))
        return core::frame_consumer::empty();
    auto name = params.size() > 1 ? u8(params.at(1)) : std::string();
    check_name(name);
    return spl::make_shared<preview_consumer>(std::move(name));
}

spl::shared_ptr<core::frame_consumer>
create_preconfigured_preview_consumer(const boost::property_tree::wptree& ptree,
                                      const core::video_format_repository& /*format_repository*/,
                                      const std::vector<spl::shared_ptr<core::video_channel>>& /*channels*/,
                                      const core::channel_info& /*channel_info*/)
{
    auto name = u8(ptree.get(L"name", L""));
    check_name(name);
    return spl::make_shared<preview_consumer>(std::move(name));
}

} // namespace caspar::image
