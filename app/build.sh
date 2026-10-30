#!/bin/sh
# Builds "Symphony Control.app" into build/ (no Xcode project needed).
set -eu
cd "$(dirname "$0")/.."
APP="build/Symphony Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos14 -parse-as-library \
    app/Sources/*.swift -o "$APP/Contents/MacOS/SymphonyControl"
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
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign -f -s - "$APP" >/dev/null 2>&1
echo "built: $APP"
