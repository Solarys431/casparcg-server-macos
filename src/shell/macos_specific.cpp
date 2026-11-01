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

#include "platform_specific.h"

#include <common/env.h>
#include <common/log.h>
#include <common/os/apple/process.h>
#include <common/utf.h>
#include <exception>

#include <boost/dll/runtime_symbol_info.hpp>
#include <boost/filesystem.hpp>
#include <boost/property_tree/ptree.hpp>

#include <boost/log/core.hpp>

#include <algorithm>
#include <chrono>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <netinet/in.h>
#include <pthread/spawn.h>
#include <signal.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>

namespace caspar {

namespace {

// Contents/ of the app bundle the executable runs from, or empty when it does not run from one.
boost::filesystem::path app_contents_folder()
{
    auto macos = boost::dll::program_location().parent_path();
    if (macos.filename() != "MacOS" || macos.parent_path().filename() != "Contents" ||
        macos.parent_path().parent_path().extension() != ".app")
        return {};
    return macos.parent_path();
}

int macos_major_version()
{
    char   version[32] = {};
    size_t size        = sizeof(version) - 1;
    if (sysctlbyname("kern.osproductversion", version, &size, nullptr, 0) != 0)
        return 0;
    return std::atoi(version);
}

std::string launch_folder;

// The helper in Contents/Helpers that the server starts and ends: the media scanner, which answers CLS, TLS, CINF,
// FLS and the thumbnails.
//
// Each run of a helper has a watcher thread that learns of its end without reaping it (waitid with WNOWAIT): until
// its pid is cleared under the mutex, the child is not reaped, so a signal sent under the mutex cannot reach another
// process that got the same pid. The mutex is never held across anything that can block: no logging, no spawning,
// no waiting.
struct helper
{
    explicit helper(const wchar_t* name)
        : name(name)
    {
    }
    const wchar_t*           name;
    std::mutex               mutex;
    std::vector<std::string> args;     // set by start_media_scanner before any thread, then only read
    std::string              folder;   // the working folder then: CEF moves the process's own later
    std::string              log_file; // absolute, for the same reason
    int                      port     = 0;
    pid_t                    pid      = 0;     // the running helper, 0 when there is none
    pid_t                    unreaped = 0;     // one that ended while the server stopped it: stop_helper reaps it
    bool                     spawning = false; // a start decided and not yet done
    bool                     stopping = false;
};
helper scanner(L"Media scanner");

bool something_answers_on(int port)
{
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return false;
    sockaddr_in address{};
    address.sin_family      = AF_INET;
    address.sin_port        = htons(static_cast<uint16_t>(port));
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    const bool answers      = connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0;
    close(fd);
    return answers;
}

void spawn_helper(helper& h);

// Starts a thread, or says why not: a thread that cannot start must not take the server down.
template <typename F>
bool start_thread(const helper& h, F&& body)
{
    try {
        std::thread(std::forward<F>(body)).detach();
        return true;
    } catch (const std::system_error& e) {
        CASPAR_LOG(warning) << h.name << L": no thread to watch it (" << u16(e.what()) << L")";
        return false;
    }
}

void watch_helper(helper& h, pid_t pid, std::chrono::steady_clock::time_point started)
{
    siginfo_t info{};
    while (waitid(P_PID, pid, &info, WEXITED | WNOWAIT) == -1 && errno == EINTR) {
    }
    {
        std::lock_guard<std::mutex> lock(h.mutex);
        if (h.pid == pid)
            h.pid = 0;
        if (h.stopping) {
            h.unreaped = pid;
            return;
        }
    }
    int status = 0;
    while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {
    }

    const auto lived = std::chrono::steady_clock::now() - started;
    const auto how   = WIFSIGNALED(status) ? L"signal " + std::to_wstring(WTERMSIG(status))
                                           : L"exit code " + std::to_wstring(WEXITSTATUS(status));
    // One that lived a while fell: it comes back. One that ends at once (a broken install, its port taken by
    // something that does not answer) would only end again, so it stays off, and the log says why.
    if (lived < std::chrono::seconds(30)) {
        CASPAR_LOG(warning) << h.name << L" ended after "
                            << std::chrono::duration_cast<std::chrono::seconds>(lived).count() << L" s (" << how
                            << L"), and stays off: see " << u16(h.log_file);
        return;
    }
    {
        std::lock_guard<std::mutex> lock(h.mutex);
        if (h.stopping)
            return;
        h.spawning = true;
    }
    CASPAR_LOG(warning) << h.name << L" ended (" << how << L"): starting it again";
    spawn_helper(h);
}

// While another program answers on the port (the user's own scanner, or the helper of a server that has just died
// and has not seen it yet), the server waits for the port to be free and then starts its own.
void wait_for_free_port(helper& h)
{
    for (;;) {
        std::this_thread::sleep_for(std::chrono::seconds(2));
        {
            std::lock_guard<std::mutex> lock(h.mutex);
            if (h.stopping)
                return;
        }
        if (something_answers_on(h.port))
            continue;
        {
            std::lock_guard<std::mutex> lock(h.mutex);
            if (h.stopping)
                return;
            h.spawning = true;
        }
        CASPAR_LOG(info) << h.name << L": port " << h.port << L" is free, starting it";
        spawn_helper(h);
        return;
    }
}

// Called with h.spawning set; clears it.
void spawn_helper(helper& h)
{
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addchdir_np(&actions, h.folder.c_str());
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, h.log_file.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    // Only 0, 1 and 2 go to the helper: holding the server's sockets, it would keep their ports taken after a
    // restart. Its own process group, which its ffmpeg and ffprobe join, so that one signal reaches them all.
    // Utility priority, below the server's channels.
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attributes, 0);
    posix_spawnattr_set_qos_class_np(&attributes, QOS_CLASS_UTILITY);

    std::vector<char*> argv;
    for (auto& arg : h.args)
        argv.push_back(arg.data());
    argv.push_back(nullptr);

    pid_t     pid   = 0;
    const int error = posix_spawn(&pid, argv[0], &actions, &attributes, argv.data(), *_NSGetEnviron());
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);

    bool stopping = false;
    {
        std::lock_guard<std::mutex> lock(h.mutex);
        h.spawning = false;
        stopping   = h.stopping;
        if (error == 0) {
            if (stopping) {
                kill(-pid, SIGKILL);
                h.unreaped = pid;
            } else {
                h.pid = pid;
            }
        }
    }
    if (error != 0) {
        CASPAR_LOG(warning) << h.name << L" could not start: " << u16(std::strerror(error));
        return;
    }
    if (stopping)
        return;

    if (!start_thread(h, [&h, pid, started = std::chrono::steady_clock::now()] { watch_helper(h, pid, started); })) {
        // Unwatched, it would never be reaped nor started again: it goes.
        {
            std::lock_guard<std::mutex> lock(h.mutex);
            if (h.pid == pid) {
                kill(-pid, SIGKILL);
                h.pid = 0;
            }
        }
        waitpid(pid, nullptr, 0);
        return;
    }
    CASPAR_LOG(info) << h.name << L": pid " << pid << L", port " << h.port << L", log " << u16(h.log_file);
}

void start_helper(helper&                  h,
                  std::vector<std::string> args,
                  int                      port,
                  const boost::filesystem::path& folder,
                  const std::string&       log_name)
{
    {
        std::lock_guard<std::mutex> lock(h.mutex);
        h.args     = std::move(args);
        h.folder   = folder.string();
        h.log_file = env::log_to_file() ? boost::filesystem::absolute(u8(env::log_folder()) + log_name, folder).string()
                                        : "/dev/null";
        h.port     = port;
        h.stopping = false;
        h.spawning = true;
    }
    if (something_answers_on(port)) {
        {
            std::lock_guard<std::mutex> lock(h.mutex);
            h.spawning = false;
        }
        CASPAR_LOG(info) << h.name << L": something already answers on port " << port
                         << L"; the server's starts when the port is free";
        start_thread(h, [&h] { wait_for_free_port(h); });
        return;
    }
    spawn_helper(h);
}

void stop_helper(helper& h)
{
    using namespace std::chrono_literals;
    {
        std::lock_guard<std::mutex> lock(h.mutex);
        h.stopping = true;
        if (h.pid != 0)
            kill(-h.pid, SIGTERM); // its group: the helper, and its ffmpeg and ffprobe
    }
    // Ended, as its watcher saw, and no start half done.
    auto ended = [&h] {
        std::lock_guard<std::mutex> lock(h.mutex);
        return h.pid == 0 && !h.spawning;
    };
    auto wait_until_ended = [&](std::chrono::milliseconds limit) {
        for (auto end = std::chrono::steady_clock::now() + limit; std::chrono::steady_clock::now() < end;) {
            if (ended())
                return true;
            std::this_thread::sleep_for(20ms);
        }
        return ended();
    };
    if (!wait_until_ended(3000ms)) {
        {
            std::lock_guard<std::mutex> lock(h.mutex);
            if (h.pid != 0)
                kill(-h.pid, SIGKILL);
        }
        wait_until_ended(2000ms);
    }
    // Reaped here, not by its watcher: after an exec, the next server would never reap it.
    pid_t left = 0;
    {
        std::lock_guard<std::mutex> lock(h.mutex);
        left       = h.unreaped;
        h.unreaped = 0;
    }
    if (left != 0)
        waitpid(left, nullptr, 0);
}

} // namespace

void start_media_scanner(const std::wstring& config_file_name)
{
    auto contents = app_contents_folder();
    if (contents.empty())
        return;
    auto helpers = contents / "Helpers";
    auto program = helpers / "media-scanner";
    if (!boost::filesystem::exists(program))
        return;

    auto choice = env::properties().get(L"configuration.media-scanner", L"auto");
    if (choice == L"none") {
        CASPAR_LOG(info) << L"Media scanner: off (<media-scanner>none</media-scanner>)";
        return;
    }
    if (choice != L"auto")
        CASPAR_LOG(warning) << L"Unknown media-scanner " << choice << L", expected auto or none.";

    auto host = env::properties().get(L"configuration.amcp.media-server.host", L"127.0.0.1");
    if (host != L"127.0.0.1" && host != L"localhost") {
        CASPAR_LOG(info) << L"Media scanner: not started, the media server is " << host;
        return;
    }
    int port = 0;
    try {
        port = std::stoi(env::properties().get(L"configuration.amcp.media-server.port", L"8000"));
    } catch (...) {
    }
    if (port <= 0 || port > 65535) {
        CASPAR_LOG(warning) << L"Media scanner: not started, the media server port is not a port";
        return;
    }

    boost::system::error_code ec;
    const auto                folder = boost::filesystem::current_path(ec);
    const auto                parent = std::to_string(getpid());
    std::vector<std::string>  tools;
    for (const auto* tool : {"ffmpeg", "ffprobe"}) {
        if (boost::filesystem::exists(helpers / tool)) {
            tools.push_back(std::string("--") + tool);
            tools.push_back((helpers / tool).string());
        }
    }

    // On this Mac only, where the server asks: the scanner lists the media and hands out their thumbnails.
    std::vector<std::string> args = {program.string(),
                                     "--config",
                                     boost::filesystem::absolute(u8(config_file_name), folder).string(),
                                     "--host",
                                     "127.0.0.1",
                                     "--port",
                                     std::to_string(port),
                                     "--genitore",
                                     parent};
    args.insert(args.end(), tools.begin(), tools.end());
    start_helper(scanner, std::move(args), port, folder, "media-scanner.log");
}

void stop_media_scanner()
{
    stop_helper(scanner);
}

void remember_launch_folder()
{
    char folder[PATH_MAX];
    if (getcwd(folder, sizeof(folder)) != nullptr)
        launch_folder = folder;
}

void restart_process()
{
    // The same pid runs the next server: the helpers would not see it end, and would keep their ports.
    stop_media_scanner();
    boost::log::core::get()->flush();

    // Descriptors stay open across exec, and the next server could not listen on ports this one
    // still holds (the watchdog in server.cpp restarts without a teardown). Marked to close on exec
    // rather than closed: CEF's threads are still running and fail hard on a descriptor gone under
    // them (its kqueue message pump checks every kevent64).
    const auto open_max = static_cast<int>(std::min<long>(sysconf(_SC_OPEN_MAX), 65536));
    for (int fd = 3; fd < open_max; ++fd) {
        const int flags = fcntl(fd, F_GETFD);
        if (flags != -1)
            fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
    }

    // CEF moves the working folder into the bundle's Resources, where the default configuration is:
    // started from there, the server would not find the one it ran with.
    if (!launch_folder.empty() && chdir(launch_folder.c_str()) != 0)
        std::cerr << "restart: could not go back to " << launch_folder << std::endl;

    char     path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) == 0)
        execv(path, *_NSGetArgv());
    std::cerr << "restart: could not run " << path << " again" << std::endl;
}

void exit_for_restart()
{
    restart_process();
    std::_Exit(5);
}

void use_app_working_folder(int argc, char** /*argv*/)
{
    auto contents = app_contents_folder();
    if (contents.empty() || argc >= 2 || boost::filesystem::exists("casparcg.config"))
        return;

    const char* home = std::getenv("HOME");
    if (home == nullptr)
        return;

    // Before anything asks for boost::filesystem::initial_path(), which keeps the first answer.
    auto                      folder = boost::filesystem::path(home) / "Library" / "Application Support" / "CasparCG Server";
    boost::system::error_code ec;
    for (const auto* sub : {"media", "template", "log", "data"})
        boost::filesystem::create_directories(folder / sub, ec);

    auto config = folder / "casparcg.config";
    if (!boost::filesystem::exists(config))
        boost::filesystem::copy_file(contents / "Resources" / "casparcg.config", config, ec);

    boost::filesystem::current_path(folder, ec);
}

void select_vulkan_driver()
{
    if (std::getenv("VK_DRIVER_FILES") != nullptr || std::getenv("VK_ICD_FILENAMES") != nullptr)
        return;

    auto contents = app_contents_folder();
    if (contents.empty())
        return;

    auto choice = env::properties().get(L"configuration.vulkan-driver", L"auto");
    if (choice != L"auto" && choice != L"kosmickrisp" && choice != L"moltenvk") {
        CASPAR_LOG(warning) << L"Unknown vulkan-driver " << choice << L", expected kosmickrisp, moltenvk or auto.";
        choice = L"auto";
    }
    if (choice == L"auto")
        choice = macos_major_version() >= 26 ? L"kosmickrisp" : L"moltenvk";

    auto icd = contents / "Resources" / "vulkan" / "icd.d" /
               (choice == L"moltenvk" ? "MoltenVK_icd.json" : "kosmickrisp_icd.json");
    if (!boost::filesystem::exists(icd)) {
        CASPAR_LOG(warning) << L"Vulkan driver " << choice << L" is not in the app bundle: " << icd.wstring();
        return;
    }

    CASPAR_LOG(info) << L"Vulkan driver: " << choice;
    setenv("VK_DRIVER_FILES", icd.string().c_str(), 1);
}

void setup_process_scheduling()
{
    // macOS does throttle background processes: App Nap and timer coalescing. Called before the CEF
    // interceptors, so the CEF subprocesses opt out too.
    disable_process_power_throttling();
}

void setup_prerequisites()
{
    // Enable utf8 console input and output
    std::wcout.sync_with_stdio(false);
    std::wcout.imbue(std::locale(""));
    std::wcin.imbue(std::locale(""));

    // XInitThreads();

    std::set_terminate([] { CASPAR_LOG_CURRENT_EXCEPTION(); });
}

void setup_console_window()
{
    // TODO: implement.
}

void increase_process_priority()
{
    // TODO: implement.
}

void wait_for_keypress()
{
    // TODO: implement if desirable.
}

std::shared_ptr<void> setup_debugging_environment()
{
    // TODO: implement if applicable.
    return nullptr;
}

void wait_for_remote_debugging()
{
    // TODO: implement if applicable.
}

} // namespace caspar
