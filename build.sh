#!/bin/bash
# Build "Filip's Mac Fixes" and install it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP="Filip's Mac Fixes.app"
BIN="MacFixes"
BUILD="build"
BUNDLE_ID="com.filipkin.macfixes"

echo "Compiling (release)..."
swift build -c release

echo "Assembling $APP..."
rm -rf "$BUILD/$APP"
mkdir -p "$BUILD/$APP/Contents/MacOS"
mkdir -p "$BUILD/$APP/Contents/Resources"

cp ".build/release/$BIN" "$BUILD/$APP/Contents/MacOS/$BIN"

cat > "$BUILD/$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>          <string>Filip's Mac Fixes</string>
    <key>CFBundleDisplayName</key>   <string>Filip's Mac Fixes</string>
    <key>CFBundleExecutable</key>    <string>$BIN</string>
    <key>CFBundleIdentifier</key>    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>       <string>1</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundlePackageType</key>   <string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key>           <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Filip's Mac Fixes uses screen capture for screenshots and screen recording.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Filip's Mac Fixes records the microphone when you enable audio in a screen recording.</string>
</dict>
</plist>
PLIST

# Sign with a stable self-signed identity if it exists (run ./setup-signing.sh
# once to create it), so macOS keeps Accessibility / Screen Recording grants
# across rebuilds. Otherwise fall back to ad-hoc, which re-prompts each rebuild.
CERT_NAME="MacFixes Self-Signed"
if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
    echo "Signing with $CERT_NAME..."
    codesign --force --deep --sign "$CERT_NAME" --identifier "$BUNDLE_ID" "$BUILD/$APP"
else
    echo "Ad-hoc signing (run ./setup-signing.sh once so permissions persist across rebuilds)."
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$BUILD/$APP"
fi

echo "Installing to /Applications..."
rm -rf "/Applications/$APP"
cp -R "$BUILD/$APP" "/Applications/$APP"

echo "Done. Launch it:"
echo "  open \"/Applications/$APP\""
