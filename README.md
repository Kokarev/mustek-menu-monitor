# MUSTEK Menu Monitor

A native macOS menu bar application that reads UPS measurements through
Network UPS Tools (NUT). Version 0.1.3 adds an exclusive process lock to prevent
two copies from appending to the same history.

This is a locally prepared source candidate licensed under the [MIT License](LICENSE).
Publication remains on hold pending separate PUBLIC-01B owner approval.

## Author

Pavel Kokarev, CEO, Alma-Soft.

## License

MIT License. Copyright (c) 2026 Pavel Kokarev.
See [LICENSE](LICENSE) for the full terms and the
[license decision](docs/LICENSE-OPTIONS.md) for publication status.

## Features

- Mains and battery status, voltage, load, temperature and NUT connection state.
- Estimated output power and daily/monthly energy totals.
- CSV measurement history and power outage transitions.
- Five-second background polling; stale readings are hidden after 15 seconds.
- One instance per user data directory, enforced with `flock(2)`.

The application only invokes `upsc`. It does not configure NUT, access USB
directly, issue UPS control commands, or shut down the computer.

## Requirements and compatibility

- macOS 13 or later is the declared deployment target.
- Swift 5.9 or later and the macOS SDK (Xcode Command Line Tools or Xcode).
- A graphical macOS user session for the menu UI and AppKit tests.
- Separately installed NUT, including an executable `upsc` and a working `upsd`.
- `/usr/bin/python3` for the lock subprocess tests, plus zsh, `plutil` and
  `codesign` for the bundle build.

The preparation build was checked on Apple Silicon with macOS 26.7.1 and Apple
Swift 6.4. Intel and the macOS 13 minimum have not been separately validated.
The original deployment used NUT 2.8.5 with `nutdrv_qx`; compatibility with other
NUT versions and UPS models depends on the variables they expose.
Required variables are `ups.status`, numeric `input.voltage` and numeric
`ups.load`. Additional measurements are optional.

## Build and test

From this directory:

```sh
swift test
./build.sh
codesign --verify --deep --strict dist/MustekMenuMonitor.app
```

There are no remote Swift packages to fetch. The app bundle is written to
`dist/MustekMenuMonitor.app`; generated files are ignored by Git. The signature
is ad hoc for local use, with no Developer ID signature or notarization.
These steps build and test; they do not install or launch the app.

The live NUT test is opt-in and skipped by default. No live readings or render
artifacts belong in the repository. See [build details](docs/BUILD.md).

## Configure and install

Before building for your UPS, edit `Upsc.path` and `Upsc.target` in
`Sources/MustekMenuMonitor/Upsc.swift`. The target `demo-ups@127.0.0.1:3493`
is a demonstration value. The default executable path is Homebrew's Apple
Silicon path, `/opt/homebrew/opt/nut/bin/upsc`. Intel or other installations may
use another path. There is no settings UI or environment override in 0.1.3.

`BatteryProfile.installed` in `Battery.swift` is a demonstration GEL profile
(12 V, 9 Ah, example date 2000-01-01). Replace it with your own data before use.
The public candidate has sanitized profile data and synthetic test values; it
is not a byte-identical copy of an existing installed build.

Follow [installation and optional login startup](docs/INSTALL.md). NUT must
already be configured independently; no user NUT configurations are included.

## Data and limitations

The interface is currently in Russian. Data is stored under
`~/Library/Application Support/MustekMenuMonitor/`:

- `history.csv`: timestamp, status, input/output voltage, load, estimated watts,
  energy increment and battery voltage.
- `power_events.csv`: outage start/end and battery voltage statistics; created
  when a transition is recorded.
- `.lock`: informational PID; the live kernel lock determines ownership.

The fixed 400 W rating used for power estimates must match your hardware.
Load percentage may not represent true watts; energy is not a utility meter
reading and excludes UPS conversion losses. Charge and remaining runtime are
not calibrated. A 10.5 V battery value is only a reference, not a control limit.
Missing samples and downtime are not backfilled. After a monitoring gap, outage
duration can be a lower bound. CSV files have no rotation and are read into
memory at startup; write failures are not surfaced as a dedicated UI error.

The lock is released by the kernel after normal exit or SIGKILL; a leftover
lock file is harmless. Older versions without the lock must not run alongside
0.1.3. The optional LaunchAgent uses **KeepAlive=false**: it starts at login,
but neither quitting nor a crash causes automatic restart. Manual restart is
described in the installation guide.

Off-screen rendering tests approximate the menu background; they do not
replace testing the actual menu on every supported macOS version. No binary
release, automatic updater, NUT setup tool or UPS shutdown policy is provided.

## Dependencies and publication

See [dependency inventory](docs/DEPENDENCIES.md) and
[preparation verification](docs/PREPARATION.md). No NUT executable, source,
driver, private configuration, measurement log or backup is distributed here.
