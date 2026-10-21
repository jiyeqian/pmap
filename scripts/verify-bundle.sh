#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-pmap.app}"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --verify --strict "$APP"
ARCHS="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/pmap")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]]
[[ -s "$APP/Contents/Resources/AppIcon.icns" ]]
[[ -s "$APP/Contents/Resources/PRIVACY.md" ]]
[[ ! -e "$APP/Contents/Resources/TestFixture" ]] || { echo 'Refusing a test-fixture bundle' >&2; exit 1; }
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, re, sys
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
assert re.fullmatch(r'\d+\.\d+\.\d+', info['CFBundleShortVersionString'])
assert re.fullmatch(r'\d+(?:\.\d+){0,2}', info['CFBundleVersion'])
assert info['NSHumanReadableCopyright']
assert info['CFBundleLocalizations'] == ['en', 'zh-Hans']
PY
if [[ "${PMAP_REQUIRE_SANDBOX:-0}" == 1 ]]; then
    /usr/bin/codesign -d --entitlements :- "$APP" 2>/dev/null | python3 -c 'import plistlib,sys; assert plistlib.loads(sys.stdin.buffer.read())["com.apple.security.app-sandbox"] is True'
fi
echo "PASS bundle validation: $APP"
