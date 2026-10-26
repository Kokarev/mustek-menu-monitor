#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release --arch arm64
APP="$PWD/dist/MustekMenuMonitor.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MustekMenuMonitor "$APP/Contents/MacOS/MustekMenuMonitor"
# SwiftPM resource bundle is copied into the installed app before signing.
mkdir -p "$APP/Contents/Resources"
ditto .build/release/MustekMenuMonitor_MustekMenuMonitor.bundle "$APP/Contents/Resources/MustekMenuMonitor_MustekMenuMonitor.bundle"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.mustek.menumanager</string>
<key>CFBundleName</key><string>MustekMenuMonitor</string>
<key>CFBundleDisplayName</key><string>MUSTEK Menu Monitor</string>
<key>CFBundleExecutable</key><string>MustekMenuMonitor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.4</string>
<key>CFBundleVersion</key><string>14</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>uk</string><string>de</string><string>ru</string></array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
[[ "$(lipo -archs "$APP/Contents/MacOS/MustekMenuMonitor")" == "arm64" ]]
# Ad-hoc signature for the whole bundle (local use only; not notarised).
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Created: $APP"
