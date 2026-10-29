#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
# The bundle ID and data directory keep their pre-0.2.0 names so an update keeps settings and history.
swift build -c release --arch arm64
APP="$PWD/dist/UPS Menu Bar.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/UPSMenuBar "$APP/Contents/MacOS/UPSMenuBar"
# SwiftPM resource bundle is copied into the installed app before signing.
mkdir -p "$APP/Contents/Resources"
ditto .build/release/UPSMenuBar_UPSMenuBar.bundle "$APP/Contents/Resources/UPSMenuBar_UPSMenuBar.bundle"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.mustek.menumanager</string>
<key>CFBundleName</key><string>UPS Menu Bar</string>
<key>CFBundleDisplayName</key><string>UPS Menu Bar</string>
<key>CFBundleExecutable</key><string>UPSMenuBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>20</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>uk</string><string>de</string><string>ru</string></array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
[[ "$(lipo -archs "$APP/Contents/MacOS/UPSMenuBar")" == "arm64" ]]
# Drop the debug map: it records absolute build paths, including the home directory.
BIN="$APP/Contents/MacOS/UPSMenuBar"
strip -S "$BIN"
check_no_build_paths() {
    if grep -a -q -F -e "$PWD" -e "$HOME" -e ".build/" "$BIN"; then
        echo "FAIL: build paths remain in $BIN" >&2; exit 1
    fi
}
check_no_build_paths
# Ad-hoc signature for the whole bundle (local use only; not notarised).
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
check_no_build_paths
echo "Created: $APP"
