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
 */

#pragma once

#include <functional>
#include <memory>
#include <string>

#include <vulkan/vulkan.hpp>

namespace caspar { namespace screen { namespace vulkan {

struct window_config
{
    std::string title;
    int         x             = 0;
    int         y             = 0;
    int         width         = 0;
    int         height        = 0;
    bool        windowed      = true;
    bool        borderless    = false;
    bool        interactive   = true;
    bool        always_on_top = false;
    int         screen_index  = 0;
};

// Platform window. On macOS all windowing calls are marshalled to the main
// thread internally (via Grand Central Dispatch); on other platforms they run
// directly on the calling (consumer render) thread.
class screen_window
{
  public:
    explicit screen_window(const window_config& config);
    ~screen_window();

    screen_window(const screen_window&)            = delete;
    screen_window& operator=(const screen_window&) = delete;

    int width() const;
    int height() const;

    // Pump window events. Returns true if the window requested close.
    bool poll();

    void framebuffer_size(int& width, int& height);

    // Block until at least one window event arrives (used during swapchain recreation
    // to wait for a minimized window to be restored without busy-spinning).
    void wait_for_events();

    vk::SurfaceKHR create_surface(vk::Instance vk_instance);
#ifdef __APPLE__
    // macOS workaround: nudge the window once so the first presented frame shows.
    void nudge_for_first_frame();
#endif

  private:
    struct impl;
    std::unique_ptr<impl> impl_;
};

#ifdef __APPLE__
// Waits until `done` returns true. On the main thread it keeps the run loop turning meanwhile: the
// consumer thread may be waiting there for a window call, which only the main thread can run, so a
// plain join from the main thread would wait for ever. Elsewhere it simply returns.
void wait_pumping_main_thread(const std::function<bool()>& done);
#endif

}}} // namespace caspar::screen::vulkan
