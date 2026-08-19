#!/bin/bash
# Builds V2T.app — a double-clickable app bundle — from the Swift package.
# Usage: ./Scripts/make-app.sh   (run from the repo root)
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building release binary…"
swift build -c release

APP=V2T.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/V2T "$APP/Contents/MacOS/V2T"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>V2T</string>
    <key>CFBundleIdentifier</key>
    <string>com.wielventures.v2t</string>
    <key>CFBundleName</key>
    <string>V2T</string>
    <key>CFBundleDisplayName</key>
    <string>V2T</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>V2T records voice memos with your microphone.</string>
    <key>NSHumanReadableCopyright</key>
    <string></string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS Gatekeeper allows it to run locally.
codesign --force --sign - "$APP"

echo
echo "Done → $(pwd)/$APP"
echo "Move it to /Applications if you like:  mv $APP /Applications/"
