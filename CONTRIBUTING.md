# Contributing

**English** · [Italiano](CONTRIBUTING.it.md)

Thank you for helping with CasparCG Server for macOS. Three channels, each for one thing:

| What | Where |
|---|---|
| A bug, or a suggestion | [Issues](../../issues): one issue per problem, after a search for an existing one |
| A fix | a [pull request](../../pulls) against `main` |
| A vulnerability | **by mail only**, to **info@danielecappello.com**, never in a public issue ([SECURITY.md](SECURITY.md)) |

A bug that also happens with an unmodified upstream build on Windows or Linux belongs
[upstream](https://github.com/CasparCG/server/issues). Questions about using CasparCG are welcome on the
[CasparCG forum](https://casparcgforum.org/).

## What a bug report needs

Without these, a bug on a Mac can rarely be reproduced. The issue form asks for each of them.

1. The chip and memory of your Mac, from the Apple menu → About This Mac (for example *Apple M4, 16 GB*).
2. The macOS version (for example *26.6.2*).
3. The release (for example `v2.6.0-macos.3`) and what `VERSION` answers on AMCP (for example
   `2.6.0 1a2b3c4d5 Dev`). From Terminal: `(printf 'VERSION\r\n'; sleep 1) | nc 127.0.0.1 5250`.
4. The Vulkan driver, KosmicKrisp or MoltenVK, which the log gives at start in the line `Vulkan driver: …`.
5. The steps that lead to the problem: the AMCP commands in order, the `casparcg.config` (without passwords), the
   kind of media (codec, resolution, frame rate) and the output (screen, file, SRT, NDI…).
6. What happened and what you expected.
7. The server's log of that session, from `~/Library/Application Support/CasparCG Server/log/` (or the
   `log-path` of your configuration). For a crash, also the report in Console → Crash Reports (a file named
   `casparcg-….ips`, in `~/Library/Logs/DiagnosticReports/`).

## Pull requests

- Branch from `main`, one topic per pull request, and write commit messages like the existing ones: `fix(macos): …`,
  `feat(image): …`, `build(macos): …`, `docs: …`.
- Build the dependencies with `tools/macos/build-deps.sh <work-dir>`, then the server with
  `tools/macos/build.sh <work-dir>`, and run what you changed on a real Mac. Say in the pull request which Macs and
  which driver, what you ran and what you measured.
- A change that touches pixels should keep the Vulkan mixer's output equal to the OpenGL mixer of Windows and Linux.
  Show the comparison, with colours whose channels all differ (a grey hides channel swaps).
- A change to a dependency goes in `tools/macos/deps.list` or `src/CMakeModules/Bootstrap_Mac.cmake` (version, address,
  SHA-256); a patch goes in `tools/macos/patches/`, with a line saying why.
- Code written with the help of AI is welcome, as long as you have run and tested it, and the pull request says so.
- Your contribution is licensed under the **GNU General Public License, version 3 or later**, as the project is.

## Conduct

Everyone here follows the [code of conduct](CODE_OF_CONDUCT.md).
