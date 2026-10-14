#!/bin/bash
# Packages Clinqy as a drag-to-Applications disk image: dist/Clinqy.dmg
# It holds Clinqy.app and an Applications shortcut. The app carries the browser extension; its setup window
# copies it out and loads it (or walks the person through loading it).
#
# The app is self-signed, not notarized (that needs a paid Apple Developer account), so the first time people
# open it macOS blocks it: System Settings → Privacy & Security → Open Anyway.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh --bundle-only
APP="build/Clinqy.app"
# Signed with the same "CursorBoy Local Signing" certificate every release (build.sh makes it once per Mac), so
# macOS keeps Clinqy's Accessibility and Screen Recording permissions when people update. Ad-hoc as a last resort.
if security find-identity | grep -q "CursorBoy Local Signing"; then
  codesign --force --deep --sign "CursorBoy Local Signing" "$APP"
else
  echo "warning: no \"CursorBoy Local Signing\" certificate; signing ad-hoc, so updates will reset permissions." >&2
  codesign --force --deep --sign - "$APP"
fi
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
