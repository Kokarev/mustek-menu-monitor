#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release --arch arm64
APP="$PWD/dist/MustekMenuMonitor.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MustekMenuMonitor "$APP/Contents/MacOS/MustekMenuMonitor"
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
