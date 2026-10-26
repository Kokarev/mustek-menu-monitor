#!/bin/zsh
# QA build for testing beside an installed copy: its own bundle ID, data directory
# (~/Library/Application Support/MustekMenuMonitor-QA), lock and settings suite.
# Never install or distribute this bundle.
set -euo pipefail
cd "${0:A:h}"
swift build -c release --arch arm64 -Xswiftc -DMUSTEK_QA --scratch-path .build/qa
APP="$PWD/dist/qa/MustekMenuMonitorQA.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/qa/release/MustekMenuMonitor "$APP/Contents/MacOS/MustekMenuMonitor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.mustek.menumanager.qa</string>
<key>CFBundleName</key><string>MUSTEK QA</string>
<key>CFBundleDisplayName</key><string>MUSTEK QA</string>
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
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Created: $APP"
