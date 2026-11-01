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
 * Author: Helge Norberg, helge.norberg@svt.se
 */

#pragma once

#include <memory>
#include <string>

namespace caspar {

void                  setup_process_scheduling();
void                  setup_prerequisites();
void                  setup_console_window();
void                  increase_process_priority();
void                  wait_for_keypress();
std::shared_ptr<void> setup_debugging_environment();
void                  wait_for_remote_debugging();

// Ends the process at once with exit code 5, the one that asks for a restart (run.sh and
// casparcg_auto_restart.bat start the server again on it); on macOS, where nothing else would,
// the process runs itself again.
[[noreturn]] void exit_for_restart();

#ifdef __APPLE__
// The working folder the process started in, for restart_process(): first thing in main.
void remember_launch_folder();
// What exit code 5 asks for, done in place: the process runs itself again from the folder and with
// the arguments and environment it started with. Returns only if that fails.
void restart_process();
// Started from Finder, an app has "/" as its working folder and no arguments. Then the server works in
// ~/Library/Application Support/CasparCG Server, seeded with the app's default configuration.
void use_app_working_folder(int argc, char** argv);
// Points the Vulkan loader at one of the drivers in the app bundle, unless VK_DRIVER_FILES is set:
// <vulkan-driver> in the configuration (kosmickrisp, moltenvk or auto), auto meaning KosmicKrisp from
// macOS 26 and MoltenVK before.
void select_vulkan_driver();
// The media scanner in the app's Contents/Helpers, which answers CLS, TLS, CINF, FLS and the thumbnails: started
// with the server when <amcp><media-server> is on this Mac and nothing answers on its port yet (otherwise as soon as
// the port is free), started again if it falls after at least 30 seconds, and ended with the server. After a crash of
// the server it is expected to end by itself: the server passes its pid with --genitore.
// <media-scanner>none</media-scanner> leaves it off.
void start_media_scanner(const std::wstring& config_file_name);
void stop_media_scanner();
#endif

} // namespace caspar
