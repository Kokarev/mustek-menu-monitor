# Building v0.1.4 independently

Required inputs are `Package.swift`, `Sources/MustekMenuMonitor/` and the bundle
build scripts. Tests live under `Tests/MustekMenuMonitorTests/`. There are no
remote Swift packages, vendored frameworks, required assets or private signing
certificates. `Package.resolved` is unnecessary without package dependencies.

Use Swift 5.9+, the macOS SDK (Xcode or Command Line Tools), zsh, `plutil`, `lipo`
and `codesign`. AppKit tests require a graphical macOS user session; lock helper
tests use `/usr/bin/python3`. The deployment target is macOS 13+.

## Production

```sh
swift test
./build.sh
plutil -lint dist/MustekMenuMonitor.app/Contents/Info.plist
codesign --verify --deep --strict dist/MustekMenuMonitor.app
lipo -archs dist/MustekMenuMonitor.app/Contents/MacOS/MustekMenuMonitor
```

The build script explicitly selects **arm64**, creates Info.plist version
**0.1.4** (build **14**), retains bundle ID `local.mustek.menumanager`, uses display
name MUSTEK Menu Monitor and verifies an ad hoc signature. Output is
`dist/MustekMenuMonitor.app`. This is not an Intel/universal build recipe.
The script never installs, launches or replaces an installed app.

## Developer QA

```sh
./build-qa.sh
```

This builds arm64 with `-DMUSTEK_QA` in its own `.build/qa` scratch directory.
Output: `dist/qa/MustekMenuMonitorQA.app`, version 0.1.4 (build 14), bundle ID
`local.mustek.menumanager.qa`, display name MUSTEK QA. It uses its own
Application Support directory and UserDefaults suite, plus visible QA labels.
No QA environment variables are required. Do not install/distribute this bundle.

## Test and distribution limits

Default tests use synthetic data and temporary directories. Live NUT access is
opt-in with `MUSTEK_LIVE_UPSC=<ups@host:port>`; leave it unset for offline tests.
`MUSTEK_RENDER_DIR` optionally exports off-screen test PNGs; leave it unset when
no artifacts are required. Crash tests signal only their own lock-holder helper.

`Package.swift` processes the four `.lproj` catalogs with English as the default
localization. Both app scripts copy the SwiftPM resource bundle into
`Contents/Resources` before signing and declare all four supported languages in
Info.plist. Keep this bundle with the executable when moving the app; do not
ship the command-line executable alone.

Generated `.build` and `dist` contents are ignored by Git. A local build is not
Developer ID signed or notarized. Building does not create/publish a ZIP, tag or
GitHub Release. Toolchain and source settings affect output; byte-for-byte
reproducibility is not promised. Publication requires separate approval.
