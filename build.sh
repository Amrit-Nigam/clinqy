#!/bin/bash
# Builds CursorBoy.app (no Xcode needed) and optionally launches it: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --build-system native
APP="build/CursorBoy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CursorBoy "$APP/Contents/MacOS/CursorBoy"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CursorBoy</string>
  <key>CFBundleIdentifier</key><string>com.amritnigam.cursorboy</string>
  <key>CFBundleExecutable</key><string>CursorBoy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>CursorBoy controls apps on your behalf.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>CursorBoy</string>
    <key>CFBundleURLSchemes</key><array><string>cursorboy</string></array>
  </dict></array>
  <key>NSMicrophoneUsageDescription</key><string>CursorBoy listens while you hold ⌥Space so you can talk to it.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>CursorBoy turns what you say into requests.</string>
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

# The `cursorboy` command (for terminals and coding agents), on the PATH next to `claude`.
mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/bin/cursorboy" "$HOME/.local/bin/cursorboy"

if [[ "${1:-}" == "run" ]]; then
  pkill -x CursorBoy 2>/dev/null && sleep 1 || true
  open "$APP"
fi
