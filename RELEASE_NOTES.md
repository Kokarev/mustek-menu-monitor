# Release notes — v0.1.4

Status: local candidate; publication, release tagging and ZIP distribution are
on strict hold pending separate approval. Final local candidate prepared in M10.

## Changes from v0.1.3

- Native bundle localizations: English (base/fallback), Ukrainian, German and
  Russian. macOS chooses the UI language, including per-app preferences.
  Display formatting follows the system locale; NUT identifiers, CSV formats,
  measurement history and calculations are unchanged. Four-language GUI
  acceptance (en, uk, de, ru, macOS system language, English fallback) was
  completed by the owner in M10.
- M10 fixes: the output-voltage row was labelled with the Quit text in
  English, Ukrainian and German (now Output); Ukrainian and Russian wording
  corrected in several settings and error messages.
- The upsc path and version line in Settings now wraps inside the window; in
  Ukrainian and Russian it previously ran past the window edge (U-1).
- Release and QA builds strip the debug map, so the executable no longer
  contains absolute build paths; the build fails if any remain (P-1).

- Native settings window: server/port, UPS name discovery, connection check,
  save/apply, optional `upsc` path and nominal UPS output power. Initial startup
  remains unconfigured until a UPS is selected; settings persist in UserDefaults.
- `upsc` auto-location at common Homebrew/MacPorts paths and a version probe.
  Unusable manual paths report errors; they are not silently replaced.
- Connection changes discard late replies from the old connection, break energy
  integration and separate open-outage ownership. Configuration interruptions
  are recorded as CFG events rather than attributed to another UPS.
- Power estimates use `ratedWatts * load_percent / 100` instead of an assumed
  rating. Missing ratings produce empty power/Wh CSV fields, not fake zeros.
  Genuine zero load is retained. Changing the rating breaks the integration
  chain and never recalculates recorded history.
- Battery display uses NUT-reported voltage, charge and runtime. A missing value
  shows No data. No static battery model, capacity, installation date,
  battery-life estimate or replacement date is assumed.
- Compile-time QA identity: separate bundle ID, data directory, settings suite
  and instance lock, plus visible QA labels. Production does not depend on QA
  environment overrides. QA is a developer artifact, not the distribution app.

## Compatibility and data

- Production: version 0.1.4, bundle ID `local.mustek.menumanager`, display name
  MUSTEK Menu Monitor, Apple Silicon arm64 build, macOS 13+ deployment target.
- QA: version 0.1.4, bundle ID `local.mustek.menumanager.qa`, name MUSTEK QA.
- `history.csv` retains eight columns. `power_events.csv` retains its schema;
  CFG events and the `open_outage_ups.txt` sidecar identify interrupted observation.
- Preserve existing CSV and saved settings on update. Unknown intervals do not
  increase totals; previously recorded Wh remain visible and are not rewritten.
- The optional existing LaunchAgent remains separate. KeepAlive=false does not
  restart an app after quit/crash. No NUT or launchd service migration is included.

## Limits and verification scope

Power/energy are approximate and depend on the UPS load percentage and entered
rating. Battery values depend on NUT and its driver. Missing data are never
replaced with invented readings. No battery age, health or service-life model,
automatic updater, log rotation, UPS control or shutdown policy is implemented.

Validation to date used Apple Silicon, macOS 26.7.1 and NUT 2.8.5. The minimum
macOS version and Intel builds have not been separately validated. Source tests
and local ad hoc signature verification do not imply notarization, Developer ID
signing or complete release acceptance. See [installation/update/rollback](docs/INSTALL.md).
