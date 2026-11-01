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

#include "window.h"

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

#include <dispatch/dispatch.h>
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3native.h>
#include <vulkan/vulkan.hpp>
#include <vulkan/vulkan_metal.h>

#include <common/except.h>
#include <common/log.h>

#include <atomic>
#include <memory>
#include <mutex>

namespace caspar { namespace screen { namespace vulkan {

namespace {
std::mutex g_glfw_mutex;
int        g_glfw_refcount = 0; // guarded by g_glfw_mutex, mutated on the main thread

// Run a block on the main thread and wait, but bail out after a timeout so we
// never hang if the main thread has stopped pumping events (e.g. shutdown).
bool run_on_main_with_timeout(double timeout_seconds, dispatch_block_t block)
{
    if ([NSThread isMainThread]) {
        block();
        return true;
    }
    // This file is not built with ARC, so the semaphore's references are ours to balance: one for
    // this function, one for the block, which may run after we have stopped waiting for it. Without
    // the releases every call leaked one, and the screen consumer calls this every few milliseconds.
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_retain(done);
    dispatch_async(dispatch_get_main_queue(), ^{
        block();
        dispatch_semaphore_signal(done);
        dispatch_release(done);
    });
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout_seconds * NSEC_PER_SEC));
    const bool      ran     = dispatch_semaphore_wait(done, timeout) == 0;
    dispatch_release(done);
    return ran;
}
} // namespace

void wait_pumping_main_thread(const std::function<bool()>& done)
{
    if (![NSThread isMainThread])
        return;
    while (!done()) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
        }
    }
}

struct screen_window::impl
{
    GLFWwindow* window_ = nullptr;
    // Keeps the display awake while the output is on it: a playout window must not go dark because
    // nobody has touched the Mac.
    id display_activity_ = nil;
    int         width_  = 0;
    int         height_ = 0;
    // Set while a poll waits in the main queue: a main thread that is busy for a moment gets one poll
    // to run when it is back, not a backlog of them.
    std::shared_ptr<std::atomic<bool>> poll_queued_ = std::make_shared<std::atomic<bool>>(false);

    explicit impl(const window_config& config)
    {
        __block bool        ok            = false;
        __block id          activity      = nil;
        __block GLFWwindow* created       = nullptr;
        __block int         final_width   = config.width;
        __block int         final_height  = config.height;
        const bool          windowed      = config.windowed;
        const bool          borderless    = config.borderless;
        const bool          interactive   = config.interactive;
        const bool          always_on_top = config.always_on_top;
        const int           screen_index  = config.screen_index;
        const int           pos_x         = config.x;
        const int           pos_y         = config.y;
        const std::string   title         = config.title;

        dispatch_sync(dispatch_get_main_queue(), ^{
            {
                std::lock_guard<std::mutex> lock(g_glfw_mutex);
                if (g_glfw_refcount == 0) {
                    if (!glfwInit()) {
                        CASPAR_LOG(error) << L"[screen] Failed to initialize GLFW";
                        return;
                    }
                }
                ++g_glfw_refcount;
            }

            glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
            glfwWindowHint(GLFW_RESIZABLE, windowed ? GLFW_TRUE : GLFW_FALSE);
            // A fullscreen output must stay up when the operator clicks on another display.
            glfwWindowHint(GLFW_AUTO_ICONIFY, GLFW_FALSE);
            if (borderless)
                glfwWindowHint(GLFW_DECORATED, GLFW_FALSE);

            // <device> picks the display, 1 being the primary one, as in the Windows consumer.
            int           count    = 0;
            GLFWmonitor** monitors = glfwGetMonitors(&count);
            GLFWmonitor*  target   = glfwGetPrimaryMonitor();
            if (screen_index > 0 && screen_index < count)
                target = monitors[screen_index];
            else if (screen_index != 0)
                CASPAR_LOG(warning) << L"[screen] Display " << screen_index + 1 << L" not found, " << count
                                    << L" available. Using the primary display.";
            if (!target) {
                // No display at all: a closed laptop with nothing attached, a Mac run without a screen. There
                // is nowhere to put the window, and GLFW crashes when asked about the missing monitor.
                CASPAR_LOG(error) << L"[screen] No display is connected; the screen consumer has nowhere to show.";
                return;
            }

            GLFWmonitor* monitor = nullptr;
            if (!windowed) {
                monitor                 = target;
                const GLFWvidmode* mode = glfwGetVideoMode(monitor);
                final_width             = mode->width;
                final_height            = mode->height;
            }

            created = glfwCreateWindow(final_width, final_height, title.c_str(), monitor, nullptr);
            if (!created)
                return;

            if (windowed) {
                // <x> and <y> are relative to the chosen display.
                int display_x = 0;
                int display_y = 0;
                glfwGetMonitorPos(target, &display_x, &display_y);
                glfwSetWindowPos(created, display_x + pos_x, display_y + pos_y);
            }
            if (!interactive)
                glfwSetInputMode(created, GLFW_CURSOR, GLFW_CURSOR_HIDDEN);
            if (always_on_top)
                glfwSetWindowAttrib(created, GLFW_FLOATING, GLFW_TRUE);

            glfwShowWindow(created);
            NSWindow* nsWindow = glfwGetCocoaWindow(created);
            [nsWindow makeKeyAndOrderFront:nil];
            [[nsWindow contentView] setNeedsDisplay:YES];
            [[nsWindow contentView] displayIfNeeded];

            activity = [[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityIdleDisplaySleepDisabled
                                                                       reason:@"CasparCG screen output"] retain];

            ok = true;
        });

        if (!ok || !created)
            CASPAR_THROW_EXCEPTION(caspar_exception() << msg_info("Failed to create GLFW window on main thread"));

        window_           = created;
        width_            = final_width;
        height_           = final_height;
        display_activity_ = activity;
    }

    ~impl()
    {
        GLFWwindow* win      = window_;
        id          activity = display_activity_;
        window_              = nullptr;
        display_activity_    = nil;
        run_on_main_with_timeout(1.0, ^{
            if (activity) {
                [[NSProcessInfo processInfo] endActivity:activity];
                [activity release];
            }
            if (win)
                glfwDestroyWindow(win);
            std::lock_guard<std::mutex> lock(g_glfw_mutex);
            if (--g_glfw_refcount == 0)
                glfwTerminate();
        });
    }

    vk::SurfaceKHR create_surface(vk::Instance vk_instance)
    {
        __block VkSurfaceKHR surface  = VK_NULL_HANDLE;
        GLFWwindow*          win      = window_;
        VkInstance           instance = static_cast<VkInstance>(vk_instance);

        dispatch_sync(dispatch_get_main_queue(), ^{
            NSWindow* nsWindow    = glfwGetCocoaWindow(win);
            NSView*   contentView = [nsWindow contentView];
            [contentView setWantsLayer:YES];

            CAMetalLayer* metalLayer = [CAMetalLayer layer];
            metalLayer.device          = MTLCreateSystemDefaultDevice();
            metalLayer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
            metalLayer.framebufferOnly = NO;
            metalLayer.contentsScale   = [nsWindow backingScaleFactor];
            [contentView setLayer:metalLayer];

            NSRect backing        = [contentView convertRectToBacking:contentView.bounds];
            metalLayer.drawableSize = CGSizeMake(backing.size.width, backing.size.height);

            VkMetalSurfaceCreateInfoEXT info{};
            info.sType  = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
            info.pLayer = (__bridge const CAMetalLayer*)metalLayer;

            // Resolve the entry point through the shared dynamic dispatcher so we do
            // not link against the Vulkan loader directly (matches the accelerator).
            auto fn = (PFN_vkCreateMetalSurfaceEXT)VULKAN_HPP_DEFAULT_DISPATCHER.vkGetInstanceProcAddr(
                instance, "vkCreateMetalSurfaceEXT");
            if (fn) {
                if (fn(instance, &info, nullptr, &surface) != VK_SUCCESS)
                    surface = VK_NULL_HANDLE;
            }
        });

        if (surface == VK_NULL_HANDLE)
            CASPAR_THROW_EXCEPTION(caspar_exception() << msg_info("Failed to create Metal Vulkan surface"));

        return surface;
    }

    bool poll()
    {
        __block bool should_close = false;
        GLFWwindow*  win          = window_;
        if (!win)
            return true;
        if (poll_queued_->exchange(true))
            return false;
        auto queued = poll_queued_;
        run_on_main_with_timeout(0.1, ^{
            queued->store(false);
            glfwPollEvents();
            if (glfwWindowShouldClose(win))
                should_close = true;
        });
        // Only GLFW's close flag closes the output. A main thread that did not get to the poll in
        // time is busy (CEF, a menu, a resize), not gone; taking that for a close stopped the output
        // for good after a 100 ms stall. Shutdown does not need it: the consumer stops on its own flag.
        return should_close;
    }

    void framebuffer_size(int& w, int& h)
    {
        __block int bw  = 0;
        __block int bh  = 0;
        GLFWwindow*  win = window_;
        run_on_main_with_timeout(0.1, ^{
            if (win)
                glfwGetFramebufferSize(win, &bw, &bh);
        });
        w = bw;
        h = bh;
    }

    void wait_for_events()
    {
        // Bounded: an unbounded wait would hold the main thread, and CEF with it, until the next
        // event reached the window.
        run_on_main_with_timeout(0.1, ^{
            glfwWaitEventsTimeout(0.1);
        });
    }

    void nudge_for_first_frame()
    {
        GLFWwindow* win = window_;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!win)
                return;
            int x = 0, y = 0;
            glfwGetWindowPos(win, &x, &y);
            glfwSetWindowPos(win, x + 1, y);
            glfwSetWindowPos(win, x, y);
        });
    }
};

screen_window::screen_window(const window_config& config)
    : impl_(std::make_unique<impl>(config))
{
}
screen_window::~screen_window() {}
int screen_window::width() const { return impl_->width_; }
int screen_window::height() const { return impl_->height_; }
vk::SurfaceKHR       screen_window::create_surface(vk::Instance vk_instance) { return impl_->create_surface(vk_instance); }
bool        screen_window::poll() { return impl_->poll(); }
void        screen_window::framebuffer_size(int& w, int& h) { impl_->framebuffer_size(w, h); }
void        screen_window::wait_for_events() { impl_->wait_for_events(); }
void        screen_window::nudge_for_first_frame() { impl_->nudge_for_first_frame(); }

}}} // namespace caspar::screen::vulkan
