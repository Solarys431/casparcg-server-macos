# Security

If you find a vulnerability in this port (the macOS build, the app, or the changes in this repository), please do not
open a public issue. Write to **info@danielecappello.com** with what you found and how to reproduce it: the Mac
(model and chip), the macOS version, the server version (the release and the answer to `VERSION`), the steps and the
logs, as [CONTRIBUTING.md](CONTRIBUTING.md) describes for bugs.

Vulnerabilities in CasparCG Server itself belong upstream: https://github.com/CasparCG/server.

AMCP has no password, by CasparCG's design: whoever reaches the port controls the server and can record files anywhere
the user running it can write. The app's default configuration keeps AMCP on the Mac itself
(`<host>127.0.0.1</host>`); opening it is a choice for trusted networks. HTML templates and pages run as trusted code, with
Chromium's sandbox and web security off, as upstream.

Dependencies are pinned with their SHA-256 in `tools/macos/deps.list`; CEF and the Vulkan SDK are binary releases. For
a security fix in a dependency, every reference to it is updated (`deps.list`, and the CMake files for CEF), the app is
rebuilt in a clean work folder, and the version that ends up inside it is checked.
