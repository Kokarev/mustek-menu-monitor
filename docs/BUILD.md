# Building independently

The required application inputs are `Package.swift`, the eight Swift files in
`Sources/MustekMenuMonitor/`, and `build.sh` for the `.app` packaging. The three
files in `Tests/MustekMenuMonitorTests/` provide the existing regression suite.
No assets, external working directory, signing certificate or third-party Swift
package is needed. `Package.resolved` is unnecessary because there are no package
dependencies.

To build from a fresh source checkout with no previous build artifacts:

```sh
swift test
./build.sh
plutil -lint dist/MustekMenuMonitor.app/Contents/Info.plist
codesign --verify --deep --strict dist/MustekMenuMonitor.app
```

`build.sh` creates the Info.plist locally, sets version 0.1.3, bundles the
release executable and verifies an ad hoc signature. It never installs the
bundle or manages a running application. Builds target the host architecture;
this is not a universal binary build recipe. Toolchain versions and source
configuration affect output; byte-for-byte reproducibility is not promised.

For a build that writes generated files into a separate scratch directory:

```sh
swift build -c release --scratch-path /tmp/mustek-demo-build
```

Default tests use synthetic NUT data and temporary directories. The live test
is skipped unless `MUSTEK_LIVE_UPSC=1` is explicitly set. `MUSTEK_RENDER_DIR`
optionally writes test PNGs; leave both variables unset for offline validation.
The crash test kills only its temporary lock-holder subprocess, not the app.
