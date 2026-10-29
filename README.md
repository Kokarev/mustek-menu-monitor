# UPS Menu Bar v0.2.0

A lightweight native macOS menu bar monitor for uninterruptible power supplies
(UPS) served by Network UPS Tools (NUT). It reads an existing NUT server through
the separately installed `upsc` client, preferring its JSON output (`upsc -j`)
and falling back to plain output for NUT versions without it.

UPS Menu Bar is an independent project. It is not affiliated with, endorsed by
or sponsored by United Parcel Service or the Network UPS Tools project. Versions
up to v0.1.4 were published as MUSTEK Menu Monitor; v0.2.0 keeps their bundle ID,
settings and data directory, so an update carries existing settings and history over.

The interface The interface supports English, Ukrainian, German and Russian using
macOS language preferences, including the app-specific language set in System
Settings. English is the base and fallback language when no supported language
is preferred. There is no in-app language selector. Displayed numbers and
dates use the system locale; NUT codes and CSV serialization stay unchanged.

**v0.2.0** is not released yet; build it from source. The latest published
release is v0.1.4 (as MUSTEK Menu Monitor) on
[GitHub Releases](https://github.com/Kokarev/mustek-menu-monitor/releases).

## Features

- Settings window for NUT server, port, UPS name, optional manual `upsc` path
  and optional nominal UPS output power in watts.
- UPS discovery, connection check and save/apply after a successful check.
  First launch opens Settings when no UPS name is saved.
- `upsc -j` JSON parsing with escaped values; plain `upsc` output for older NUT.
  An upsc without `-j` switches to plain output until restart, damaged JSON
  falls back for one poll only, and a connection failure never switches.
- Automatic `upsc` lookup at standard Homebrew/MacPorts locations and a
  diagnostic version check. An unusable manual path is reported, not replaced.
- OL/OB/LB status, input/output voltage, frequency, load, temperature and link
  diagnostics. Polling runs every five seconds; stale data is hidden.
- Battery voltage, charge and runtime in seconds when supplied by NUT.
  Missing battery values display **No data**, not invented values or zero.
- Approximate power and daily/monthly energy based on configured nominal power.
- Append-only measurement CSV and outage event history; switching UPS closes
  observation of the previous UPS with a configuration-change event.
- Per-data-directory single-instance locking. A separate compile-time QA build
  has its own application identity, settings and data, plus visible QA labels.

The monitor does not configure NUT, access USB directly, issue UPS control
commands, or shut down the computer. There is no automatic updater or installer.

## Requirements

- **Apple Silicon (arm64)** for the prepared app build; no Intel/universal ZIP
  is provided by these build scripts.
- **macOS 13 or later** is the deployment target. Validation so far used macOS
  26.7.1 on Apple Silicon; the minimum OS has not been separately validated.
- A graphical macOS user session.
- Independently installed NUT `upsc` and an accessible, already configured `upsd`.
  NUT 2.8.5 was used during validation; compatibility with other versions and
  models depends on the variables exposed by their drivers.

Required variables: `ups.status`, numeric `input.voltage`, numeric `ups.load`.
Battery measurements, output voltage, frequency and temperature are optional.
Source builds additionally need Swift 5.9+, the macOS SDK, zsh, `plutil`, `lipo`
and `codesign`. Lock subprocess tests require `/usr/bin/python3`. There are no
remote Swift package dependencies. See [build instructions](docs/BUILD.md).

## Install and configure

See [INSTALL.md](docs/INSTALL.md) for installation from the release ZIP, first
launch, login startup, updates and rollback. NUT is not bundled and must be managed independently.

In **Settings…**, enter the server, port and UPS name; discover names with
**Find** if needed. Use **Check** to check and **Save** to persist
and apply a working configuration. No source edits or environment variables
are needed. Saved settings do not change the NUT server configuration.

## Measurements and limits

Estimated power is `ratedWatts * load_percent / 100`. Enter the nominal UPS
output power in watts in Settings, or leave it empty when unknown. Percentage
load may not correspond to true watts; this is an approximate UPS output-energy
estimate, not a wall-energy meter, and excludes UPS conversion losses.

Without a nominal power value, new `estimated_W` and `delta_Wh` fields are
empty. A genuine zero load with a known rating records zero watts. The first
point after a gap or rating change has no energy interval. Changing the rating
breaks integration without rewriting history; recorded Wh remain visible.

Battery voltage, charge and runtime depend on NUT and its driver. Zero and
absence are distinct. The app does not infer charge/runtime from voltage or
calculate battery age, health, remaining service life or a replacement date.

Missing samples and downtime are not backfilled. Outage duration after a gap
may be a lower bound. CSV files have no rotation and are read at startup;
write failures have no dedicated UI error. Off-screen tests do not replace
GUI checks on every supported OS.

## Data and identities

Production version **0.2.0** (identifiers kept from v0.1.x for compatibility):

- Bundle ID: `local.mustek.menumanager`; display name: **UPS Menu Bar**;
  app `UPS Menu Bar.app`, executable `UPSMenuBar`.
- Data: `~/Library/Application Support/MustekMenuMonitor/`.
- Settings: standard UserDefaults for the production application domain.

QA version **0.2.0** (developer use only):

- Bundle ID: `local.mustek.menumanager.qa`; display name: **UPS Menu Bar QA**.
- Data: `~/Library/Application Support/MustekMenuMonitor-QA/`.
- Settings suite: `local.mustek.menumanager.qa.settings`; compiled with `UPSMENUBAR_QA`.

Each data directory contains `history.csv`, `power_events.csv`, the
`open_outage_ups.txt` ownership sidecar when an outage is open, and `.lock`.
The measurement CSV retains its eight-column schema. Preserve the entire
production data directory and saved settings when updating. Do not delete a
live lock file. The kernel releases its lock after exit or crash.

Login startup is optional and separately configured with a LaunchAgent.
**KeepAlive=false** means no automatic restart after quit/crash. There is no
settings-window switch that installs or changes a LaunchAgent.

## Author and license

Pavel Kokarev, CEO, Alma-Soft.

[MIT License](LICENSE). Copyright (c) 2026 Pavel Kokarev.
See [release notes](RELEASE_NOTES.md) and [dependency inventory](docs/DEPENDENCIES.md).
NUT, its drivers and its licenses are separate; no NUT binary, configuration,
measurement history or backup is included in this source tree.
