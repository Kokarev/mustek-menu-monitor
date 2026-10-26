# Dependency and licensing inventory

## Included source

The package contains application Swift sources, XCTest files, its package
manifest and local production/QA bundle build scripts. No vendored libraries,
third-party packages, copied license notices or binary assets were found in
the supplied source tree. The supplied project originally had no LICENSE file;
the owner has since approved MIT with Copyright (c) 2026 Pavel Kokarev, and the
standard text is now included in [LICENSE](../LICENSE).

## Build and system dependencies

| Component | Use | Distributed in this repository |
| --- | --- | --- |
| Swift / Swift Package Manager | Compile and package | No |
| macOS Foundation and AppKit | Files, process execution and UI | No |
| XCTest | Test suite | No |
| zsh, plutil, lipo, codesign | Local app bundle build | No |
| Python 3 with fcntl | Temporary subprocess lock tests | No |
| macOS flock / POSIX APIs | Single-instance lock | System APIs only |

The Apple SDK and tools remain subject to their own distribution terms; no
SDK files are copied. A system framework import is not vendored source.

## External runtime dependency: Network UPS Tools

The app starts the user-installed `upsc` executable as a child process, consumes
its text output and never links libupsclient or bundles NUT. The original
deployment used NUT 2.8.5; minimum cross-version compatibility is not established.

NUT 2.8.5's [COPYING](https://github.com/networkupstools/nut/blob/v2.8.5/COPYING)
states that most files are GPL-2.0-or-later, with component-specific exceptions.
No NUT code, executable, driver or user configuration is redistributed in this
source candidate. If future packaging bundles NUT or imports its source,
stop and review the licenses of the exact components before distribution.
NUT's separate licenses do not replace the monitor project's approved MIT License.
