#!/bin/sh
# Builds "Symphony Control.app" into build/ with Swift Package Manager (release configuration).
set -eu
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
APP="build/Symphony Control.app"
swift build -c release --package-path app 2>&1 | grep -v "^\[" || true
BIN="$(swift build -c release --package-path app --show-bin-path)/SymphonyControl"
[ -x "$BIN" ] || { echo "app build failed" >&2; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SymphonyControl"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>ca.arraymusic.symphonycontrol</string>
	<key>CFBundleName</key><string>Symphony Control</string>
	<key>CFBundleDisplayName</key><string>Symphony Control</string>
	<key>CFBundleExecutable</key><string>SymphonyControl</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>Input Processing reads the Symphony's inputs to run your plugins on them.</string>
</dict>
</plist>
PLIST
codesign -f -s - "$APP" >/dev/null 2>&1
echo "built: $APP ($VERSION)"
