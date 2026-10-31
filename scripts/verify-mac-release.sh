#!/bin/bash
# Read-only validation of the distributable; never runs or installs the app.
set -euo pipefail
cd "$(dirname "$0")/.."
ARTIFACTS=${1:-dist}
VERSION=$(tr -d '[:space:]' < MAC_VERSION)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
ARTIFACTS=$(cd "$ARTIFACTS" && pwd)
(cd "$ARTIFACTS" && shasum -a 256 -c Clinqy.dmg.sha256)
hdiutil verify "$ARTIFACTS/Clinqy.dmg" >/dev/null
MOUNT=$(mktemp -d)
MOUNTED=0
cleanup() { if [[ "$MOUNTED" == 1 ]]; then hdiutil detach -quiet "$MOUNT"; fi; rmdir "$MOUNT" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$ARTIFACTS/Clinqy.dmg" >/dev/null
MOUNTED=1
APP="$MOUNT/Clinqy.app"
codesign --verify --deep --strict "$APP"
python3 - "$APP" "$VERSION" <<'PY'
from pathlib import Path
import json, plistlib, sys
app=Path(sys.argv[1]); version=sys.argv[2]
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.amritnigam.clinqy'
assert info['CFBundleShortVersionString']==version
assert info['LSMinimumSystemVersion']=='14.0'
parts=[int(p) for p in version.split('.')]
assert info['CFBundleVersion']==str(parts[0]*10000+parts[1]*100+parts[2])
resources=app/'Contents/Resources'
for name in ['clinqy','env.example','skills/clinqy/SKILL.md','extension/page.js','extension/bridge.js','GeistMono-Variable.woff2']:
 assert (resources/name).is_file(), name
expected=json.loads(Path('extension/manifest.json').read_text())['version']
assert json.loads((resources/'extension/manifest.json').read_text())['version']==expected
for name in ['page.js','bridge.js','activity.js','manifest.json']:
 assert (resources/'extension'/name).read_bytes()==(Path('extension')/name).read_bytes(),name
assert (app/'Contents/MacOS/Clinqy').is_file()
print('PASS signed Mac '+version+' DMG, bundle metadata, CLI, skills, fonts and extension')
PY
