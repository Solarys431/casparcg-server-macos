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

// macOS-specific main loop helpers.
//
// Cocoa requires all window/event handling on the main thread, and Grand
// Central Dispatch blocks enqueued on the main queue (dispatch_async/_sync to
// dispatch_get_main_queue()) only run while the main thread pumps its run loop.
// The Vulkan screen consumer marshals all GLFW/Cocoa calls to the main thread
// via the main queue, so the main thread must process events. We do not call
// [NSApplication run]; instead the server's main thread calls
// macos_process_events() in a loop while ASIO runs on a background thread.

#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>

#ifdef ENABLE_HTML
// CEF requires the host NSApplication to conform to CefAppProtocol when its
// browser-process message loop is pumped on the main thread.
#include "include/cef_application_mac.h"
#endif

// NSApplication subclass that tracks |isHandlingSendEvent|, which CEF requires
// on macOS (CefAppProtocol). Without it CEF aborts when initialized on the main
// thread. The methods are harmless when the HTML/CEF module is not built.
#ifdef ENABLE_HTML
@interface CasparApplication : NSApplication <CefAppProtocol>
#else
@interface CasparApplication : NSApplication
#endif
{
  @private
    BOOL handlingSendEvent_;
}
@end

// How a quit from the menu, the Dock or a logout reaches the server; set by the shell's run(). A quit is also
// remembered, for one that comes before the handler is set or during the teardown of a RESTART.
static void (*quit_handler)(void*) = nullptr;
static void* quit_context          = nullptr;
static bool  quit_requested        = false;

@implementation CasparApplication
- (BOOL)isHandlingSendEvent
{
    return handlingSendEvent_;
}
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent
{
    handlingSendEvent_ = handlingSendEvent;
}
- (void)sendEvent:(NSEvent*)event
{
#ifdef ENABLE_HTML
    CefScopedSendingEvent sendingEventScoper;
#endif
    [super sendEvent:event];
}
// Every quit ends here: the menu, the Dock, a quit Apple event, a logout. AppKit's own terminate: asks the
// application delegate first, and the screen consumer's GLFW installs one that turns a quit into a close
// request to its windows and cancels it, so the server could only be force quit and held up a logout; with
// no delegate, AppKit calls exit() without shutting the server down. Shut it down as SIGTERM does instead.
- (void)terminate:(id)sender
{
    quit_requested = true;
    if (quit_handler)
        quit_handler(quit_context);
}
// The quit Apple event, which the Dock, a logout and other apps send. AppKit installs its own handler in
// -finishLaunching, which only -[NSApplication run] calls and our event loop does not, so without this one the
// Dock's Quit never arrived.
- (void)handleQuitEvent:(NSAppleEventDescriptor*)event withReplyEvent:(NSAppleEventDescriptor*)reply
{
    [self terminate:nil];
}
@end

// The application menu, with Quit (⌘Q). GLFW built one only on the launch path that crashed (see the GLFW patch
// in tools/macos/patches), so the app usually had none. Not -finishLaunching: right after it macOS does not yet
// count the launch as finished, and GLFW would then wait in a [NSApp run] for a notification that has gone.
static void install_menu()
{
    NSString* name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    if (name == nil)
        name = [[NSProcessInfo processInfo] processName];

    NSMenu* app_menu = [[NSMenu alloc] initWithTitle:name];
    [app_menu addItemWithTitle:[@"Hide " stringByAppendingString:name] action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem* others = [app_menu addItemWithTitle:@"Hide Others"
                                             action:@selector(hideOtherApplications:)
                                      keyEquivalent:@"h"];
    [others setKeyEquivalentModifierMask:NSEventModifierFlagOption | NSEventModifierFlagCommand];
    [app_menu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [app_menu addItem:[NSMenuItem separatorItem]];
    [app_menu addItemWithTitle:[@"Quit " stringByAppendingString:name] action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenuItem* app_item = [[NSMenuItem alloc] init];
    [app_item setSubmenu:app_menu];
    NSMenu* bar = [[NSMenu alloc] init];
    [bar addItem:app_item];
    [NSApp setMainMenu:bar];
}

static NSApplication* sharedApp = nil;

static void install_quit_handler()
{
    [[NSAppleEventManager sharedAppleEventManager] setEventHandler:NSApp
                                                       andSelector:@selector(handleQuitEvent:withReplyEvent:)
                                                     forEventClass:kCoreEventClass
                                                        andEventID:kAEQuitApplication];
}

// Defined in the html (CEF) module; weak so the shell still links when the HTML
// module is disabled (then null and skipped). On macOS CEF runs on the main
// thread, so it is pumped here as part of main-thread event processing - this
// keeps the CEF-specific workaround out of the shared shell main loop.
extern "C" void caspar_html_tick(void) __attribute__((weak));

extern "C" {

void macos_set_quit_handler(void (*handler)(void*), void* context)
{
    quit_handler = handler;
    quit_context = context;
    if (quit_handler && quit_requested)
        quit_handler(quit_context);
}

bool macos_quit_requested() { return quit_requested; }

void macos_init_app()
{
    @autoreleasepool {
        if (sharedApp == nil) {
            // Instantiate our CefAppProtocol-conforming NSApplication as the
            // shared instance before anything else touches +sharedApplication.
            sharedApp = [CasparApplication sharedApplication];
            [sharedApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            install_quit_handler();
            // On the launch path where GLFW runs -finishLaunching, AppKit puts its own quit handler in place of
            // ours, and that one asks GLFW's application delegate, which cancels: take it back, then and once
            // -finishLaunching has returned.
            [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification*) {
                                                              install_quit_handler();
                                                              CFRunLoopPerformBlock(CFRunLoopGetMain(),
                                                                                    kCFRunLoopCommonModes,
                                                                                    ^{ install_quit_handler(); });
                                                          }];
            install_menu();
        }
    }
}

void macos_process_events(double timeout_seconds)
{
    @autoreleasepool {
        if (sharedApp == nil) {
            macos_init_app();
        }

        NSDate* limitDate = [NSDate dateWithTimeIntervalSinceNow:timeout_seconds];

        while (true) {
            NSEvent* event = [sharedApp nextEventMatchingMask:NSEventMaskAny
                                                    untilDate:limitDate
                                                       inMode:NSDefaultRunLoopMode
                                                      dequeue:YES];
            if (event == nil) {
                break;
            }
            [sharedApp sendEvent:event];
            [sharedApp updateWindows];
        }

        // Run the run loop briefly to ensure GCD main-queue blocks are processed.
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];

        // Pump CEF on the main thread (no-op when the HTML module is absent).
        if (caspar_html_tick)
            caspar_html_tick();
    }
}

} // extern "C"
