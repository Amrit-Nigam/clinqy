#!/bin/bash
# Packages Clinqy as a drag-to-Applications disk image: dist/Clinqy.dmg
# It holds Clinqy.app and an Applications shortcut. The app carries the browser extension; its setup window
# copies it out and loads it (or walks the person through loading it).
#
# The app is ad-hoc signed, not notarized (that needs a paid Apple Developer account), so the first time people
# open it macOS blocks it: System Settings → Privacy & Security → Open Anyway.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --bundle-only
APP="build/Clinqy.app"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/Clinqy.app"
ln -s /Applications "$STAGE/Applications"

DMG="dist/Clinqy.dmg"
rm -f "$DMG"
hdiutil create -volname "Clinqy $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Made $DMG ($(du -h "$DMG" | cut -f1)), version $VERSION"
