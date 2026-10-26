# Installing and updating v0.1.4 (Apple Silicon)

These are instructions for a future approved deployment. M7 prepares local
metadata and documentation only: it does not publish a ZIP, install, launch or
replace an app. Do not apply these instructions to an existing deployment
without its owner's authorization.

## Prerequisites

Use an Apple Silicon Mac with macOS 13+. The prepared build is arm64 only, not
an Intel or universal build. macOS 13 is the declared minimum; validation was
performed on macOS 26.7.1. NUT `upsc` must be installed independently and an
existing NUT server must already serve the UPS. See the
[official NUT documentation](https://networkupstools.org/documentation.html).
This app does not install/configure NUT, change driver services or use UPS
control credentials. Required telemetry is `ups.status`, `input.voltage` and
`ups.load`; other displayed measurements depend on the driver.

## Install from an approved ZIP

1. Once an approved v0.1.4 ZIP is available, obtain it from the owner's announced
   distribution location. No release download URL is available from this M7 step.
2. Compare the ZIP checksum with the checksum supplied for that exact artifact,
   when provided. Extract it in Finder and locate `MustekMenuMonitor.app`.
3. Ensure an older production copy is not running. For an existing installation,
   follow the backup/update procedure below before replacing anything.
4. For a fresh installation, copy the app to `~/Applications/`. The expected
   path for the optional LaunchAgent is `~/Applications/MustekMenuMonitor.app`.
5. Use Finder Get Info to check version **0.1.4**. The production bundle ID is
   `local.mustek.menumanager`, with display name **MUSTEK Menu Monitor**.

The local build is ad hoc signed, without Developer ID signing or notarization.
A downloaded build may be blocked by Gatekeeper. Do not disable Gatekeeper or
remove quarantine wholesale. Review the source and your macOS policy; if the
artifact is not acceptable under that policy, stop and use an approved build.
This project does not include an automatic security-policy bypass.

## First launch and connection settings

Open the copied production app in Finder. It appears in the menu bar with no
Dock icon. If no UPS name is saved, Settings opens automatically. Otherwise,
open **Settings…** from the status menu. Interface names below are the English
ones; the app shows them in your macOS language (English, Ukrainian, German or
Russian).

1. Enter the NUT server and port; initial defaults are `127.0.0.1` and `3493`.
   A new installation has no assumed UPS name.
2. Enter the UPS name, or use **Find** to list UPS names on the selected server.
   For example, if your server actually exposes a UPS named `mustek`, select it
   to form `mustek@127.0.0.1:3493`. This is an example, not a hardcoded target.
3. Normally leave manual `upsc` selection off. The app checks standard Homebrew
   and MacPorts paths, beginning with `/opt/homebrew/bin/upsc` and
   `/opt/homebrew/opt/nut/bin/upsc`. It does not search shell PATH. If needed,
   enable manual selection and choose an executable file; an invalid explicit
   path produces an error rather than silently switching to another program.
4. Enter **Nominal power, W** if known (1–100000 W, decimal point or
   comma accepted), or leave it empty. Use the UPS output rating, not battery
   capacity or a guessed value. An empty field disables new power/Wh estimates.
5. Click **Check**. It queries the selected UPS without saving. Then click
   **Save**, which checks again before saving and applying the settings.
   A failed check/save leaves the previously active configuration in effect.
6. Confirm the active target, status and values in the settings window, then
   close that window and inspect the menu. Settings persist across launches.

No battery profile needs to be configured. The menu uses NUT battery voltage,
charge and runtime in seconds. If absent, it shows **No data**; it does not
invent capacity, installation date, age, service life or replacement dates.
A real zero remains zero. Battery accuracy depends on NUT and the driver.
Power and energy are approximate calculations from load percentage and the
configured UPS rating. Historical Wh remain available when the rating is empty.

## Data to preserve

Always preserve `~/Library/Application Support/MustekMenuMonitor/` when updating:

- `history.csv`: the existing eight-column measurements and recorded Wh.
- `power_events.csv`: outage history, including configuration-change events.
- `open_outage_ups.txt`: ownership of an open outage, when present.
- `.lock`: PID information for single-instance locking; not a settings file.

Settings use the production UserDefaults domain `local.mustek.menumanager`
(normally backed by `~/Library/Preferences/local.mustek.menumanager.plist`).
Keep a local backup of that preference file/domain as well as the CSV directory.
Do not publish these files or include them in an app ZIP. A backup made while
CSV files are still being written is not a consistent stopped-app snapshot.

## Update an existing installation

1. Quit the old production app through its own menu and verify it has exited.
   Keep NUT and its services running. Never run two production versions together.
2. Copy the complete stopped-app data directory and saved settings to a dated,
   private backup folder. Keep a separate copy of the previous `.app` bundle.
   Do not delete or overwrite measurement CSV while updating.
3. Replace only the `.app` bundle at the same installation path with the
   approved v0.1.4 app. Do not replace the Application Support directory,
   preference domain, LaunchAgent or NUT configuration.
4. Launch the new app manually, or start the existing loaded LaunchAgent when
   the app is stopped. Confirm version, target, settings and historical totals.
   If upgrading from v0.1.3, set up the connection in Settings when prompted;
   the old history is retained and is not recalculated.

New unknown power/energy intervals are empty CSV fields, not zero. A nominal
power change breaks integration; old measurements and Wh are left intact.
UPS connection changes do not mix the open outage of one UPS with another.

## Return to the previous version

1. Quit v0.1.4 and verify it has exited. Make a separate backup of its current
   data/settings first; preserve any measurements added since the update.
2. Replace only the app bundle with your saved previous `.app`, using the same
   path. Keep data and NUT unchanged and do not start QA as a rollback substitute.
3. Launch the previous app and check its behavior. Older versions may ignore
   v0.1.4 settings or skip rows whose Wh are empty, and may show older estimates.
   The app has no automatic rollback or CSV conversion/merging facility.
4. If restoring a pre-update data/settings backup is necessary, do so only while
   the app is stopped and retain the newer backup separately. Do not overwrite
   newer measurements without a separate decision about those data.

## Optional login startup and QA

The app does not install a LaunchAgent. The inactive template
`examples/local.mustek.menumonitor.plist.in` requires replacing `__HOME__` with
an actual absolute home path; launchd does not expand `~` or shell variables.
Its program path expects the production app under `~/Applications/`. Loading
or changing the template is a separate deployment action, not a step performed
by the app or M7. Preserve a working LaunchAgent during updates.

`RunAtLoad=true` launches the agent when loaded, including login.
**KeepAlive=false** means quitting or crashing does not trigger an automatic
restart. If the production agent is already loaded and the app is stopped,
manual restart uses `launchctl kickstart gui/<UID>/local.mustek.menumonitor`
with the actual numeric UID. Do not use `kickstart -k` on a healthy instance or
delete its live lock. A stale lock file after exit does not hold a kernel lock.

Developer QA uses `MustekMenuMonitorQA.app`, display name **MUSTEK QA**, bundle
ID `local.mustek.menumanager.qa`, data directory
`~/Library/Application Support/MustekMenuMonitor-QA/` and settings suite
`local.mustek.menumanager.qa.settings`. Both builds report version 0.1.4;
QA is identified by its name, bundle ID and visible QA prefix. Do not install,
distribute or substitute the QA bundle for the production app.
