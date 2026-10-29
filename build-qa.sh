#!/bin/zsh
# QA build for testing beside an installed copy: its own bundle ID, data directory
# (~/Library/Application Support/MustekMenuMonitor-QA), lock and settings suite.
# Never install or distribute this bundle.
set -euo pipefail
cd "${0:A:h}"
swift build -c release --arch arm64 -Xswiftc -DUPSMENUBAR_QA --scratch-path .build/qa
APP="$PWD/dist/qa/UPS Menu Bar QA.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/qa/release/UPSMenuBar "$APP/Contents/MacOS/UPSMenuBar"
# SwiftPM resource bundle is copied into the installed app before signing.
mkdir -p "$APP/Contents/Resources"
ditto .build/qa/release/UPSMenuBar_UPSMenuBar.bundle "$APP/Contents/Resources/UPSMenuBar_UPSMenuBar.bundle"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.mustek.menumanager.qa</string>
<key>CFBundleName</key><string>UPS Menu Bar QA</string>
<key>CFBundleDisplayName</key><string>UPS Menu Bar QA</string>
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
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
check_no_build_paths
echo "Created: $APP"
