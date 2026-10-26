# PUBLIC-01A local preparation

Status: local source preparation completed. Publication remains on strict hold.
The owner must select a license, confirm source distribution rights and grant
separate PUBLIC-01B authorization before any remote repository is created.

## Inputs and changes

The supplied 0.1.3 working tree was read without modifying it. Only the package
manifest, build script, eight application source files and three test files
were copied. Build caches, app bundles, logs, private configuration and backups
were excluded. The new documentation and LaunchAgent template are independent
of the working deployment.

Privacy-related changes in this candidate:

- Battery model, installation date and condition replaced with a clearly
  identified demonstration profile; matching presentation assertions updated.
- NUT target changed to demonstration name `demo-ups` on loopback.
- Device-capture test data replaced with synthetic measurement values and
  described as such; corresponding assertions updated.
- A date-format comment changed to an example date.

The installed application's behavior and binary were not changed. This source
candidate must be configured for a user's UPS before installation; it is not a
byte-identical reproduction of a private deployment's executable.

## Validation

- Fresh local directory with no copied `.build`, `.swiftpm` or `dist` inputs.
- `swift test`: 27 test cases, zero failures; 26 passed and one opt-in live NUT
  test skipped. Live query and image-export environment flags were unset.
- `./build.sh`: release compilation and `.app` packaging succeeded.
- Info.plist lint and `codesign --verify --deep --strict`: passed.
- `otool -L`: system Apple / Swift libraries only, no NUT library linkage.
- Inactive example LaunchAgent: plist lint passed; KeepAlive is false.
- Toolchain: Apple Swift 6.4, arm64, macOS 26.7.1.
- No new application instance launched and no live UPS query requested by the
  validation. Lock crash tests used their own temporary helper process.

## Publication file review

All candidate files were read and checked with targeted text patterns for
private paths, account names, credentials, private keys, hardware serials and
non-demo network addresses. No credential or third-party code license conflict
was identified. This is a local source review, not an external security audit
or a proof of historical authorship.

No real history CSV, NUT user configuration, backup, binary, screenshot or build
log is included. Tests use temporary data directories. Generated build and test
artifacts are ignored. The LaunchAgent template uses `__HOME__`, not a real
account path. Local Git commit identity is a neutral example identity.

Checks of protected input hashes confirmed that the supplied working source,
installed binary and active LaunchAgent were unchanged. The pre-check history
prefix remained intact while the existing application continued normal append
operations with the same PID.

Before publication: resolve the pending project license and copyright holder,
review the final file list, then obtain PUBLIC-01B. No remote, release, binary
upload or publication is part of PUBLIC-01A.
