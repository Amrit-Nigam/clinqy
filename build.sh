#!/bin/bash
# Builds Clinqy.app (no Xcode needed) and optionally launches it: ./build.sh [run]
# ./build.sh --bundle-only builds build/Clinqy.app and stops there (make-dmg.sh uses it).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --build-system native
APP="build/Clinqy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/Clinqy "$APP/Contents/MacOS/Clinqy"
# What a downloaded copy needs without the repo: the browser extension (setup copies it out for "Load unpacked"),
# the `clinqy` command (setup links it into ~/.local/bin) and the fonts setup is drawn with.
cp -R extension "$APP/Contents/Resources/extension"
cp bin/clinqy "$APP/Contents/Resources/clinqy"
cp env.example "$APP/Contents/Resources/env.example"
cp website/public/fonts/GeistPixel-Square.woff2 website/public/fonts/GeistMono-Variable.woff2 "$APP/Contents/Resources/"

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
  <key>CFBundleShortVersionString</key><string>0.2.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
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

# Stable local identity keeps macOS permissions across rebuilds. macOS keys Accessibility and Screen Recording
# grants to the signature: an ad-hoc one changes every build, so a rebuilt app silently loses them while
# System Settings still shows the switch on. Signing with the same certificate every time keeps them.
IDENTITY="CursorBoy Local Signing"
if ! security find-identity | grep -q "$IDENTITY"; then
  echo "Creating the self-signed \"$IDENTITY\" certificate in your login keychain (once per Mac)…"
  TMP=$(mktemp -d)
  cat > "$TMP/cfg" <<EOF
[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=$IDENTITY
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
  if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
       -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null \
     && /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -out "$TMP/id.p12" -passout pass:clinqy \
     && security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P clinqy -T /usr/bin/codesign >/dev/null; then
    # Grants made to earlier ad-hoc builds point at a signature that no longer exists; clear them so the
    # switches in System Settings match reality and Clinqy can ask again.
    for service in Accessibility ScreenCapture PostEvent ListenEvent; do
      tccutil reset "$service" com.amritnigam.clinqy >/dev/null 2>&1 || true
    done
    echo "Signing identity created. Turn Clinqy on again under Accessibility and Screen Recording; from now on rebuilds keep it."
  fi
  rm -rf "$TMP"
fi
if security find-identity | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "warning: couldn't create \"$IDENTITY\"; signing ad-hoc, so macOS permissions reset on every rebuild." >&2
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
[[ "${1:-}" == "--bundle-only" ]] && exit 0

# Run from /Applications, not from inside ~/Desktop: an app living in a protected folder keeps
# getting macOS's "access files in your Desktop/Documents folder" prompt on every launch.
INSTALLED="/Applications/Clinqy.app"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
echo "Installed $INSTALLED"

# The `clinqy` command (for terminals and coding agents), on the PATH next to `agy`.
mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/bin/clinqy" "$HOME/.local/bin/clinqy"

if [[ "${1:-}" == "run" ]]; then
  pkill -x Clinqy 2>/dev/null && sleep 1 || true
  open "$INSTALLED"
fi
