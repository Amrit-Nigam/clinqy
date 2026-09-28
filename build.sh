#!/bin/bash
# Builds Clinqy.app (no Xcode needed) and optionally launches it: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --build-system native
APP="build/Clinqy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/Clinqy "$APP/Contents/MacOS/Clinqy"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clinqy</string>
  <key>CFBundleIdentifier</key><string>com.amritnigam.clinqy</string>
  <key>CFBundleExecutable</key><string>Clinqy</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Clinqy controls apps on your behalf.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Clinqy</string>
    <key>CFBundleURLSchemes</key><array><string>clinqy</string></array>
  </dict></array>
  <key>NSMicrophoneUsageDescription</key><string>Clinqy listens while you hold ⌥Space so you can talk to it.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Clinqy turns what you say into requests.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Clinqy adds and looks up events when you ask ("schedule a call with Priya Thursday afternoon").</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Clinqy adds and checks off reminders when you ask.</string>
</dict>
</plist>
PLIST

# Stable local identity keeps macOS permissions across rebuilds; falls back to ad-hoc.
if security find-identity | grep -q "CursorBoy Local Signing"; then
  codesign --force --deep --sign "CursorBoy Local Signing" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"

# Run from /Applications, not from inside ~/Desktop: an app living in a protected folder keeps
# getting macOS's "access files in your Desktop/Documents folder" prompt on every launch.
INSTALLED="/Applications/Clinqy.app"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
echo "Installed $INSTALLED"

# The `clinqy` command (for terminals and coding agents), on the PATH next to `claude`.
mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/bin/clinqy" "$HOME/.local/bin/clinqy"

if [[ "${1:-}" == "run" ]]; then
  pkill -x Clinqy 2>/dev/null && sleep 1 || true
  open "$INSTALLED"
fi
