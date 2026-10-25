#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
VERSION="${PMAP_VERSION:-0.2.0}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${PMAP_BUILD_NUMBER:-4}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version: $VERSION" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo 'Invalid build number' >&2; exit 1; }
SANDBOX="${PMAP_SANDBOX:-0}"
APP="${PMAP_OUTPUT_APP:-$([[ "$SANDBOX" == 1 ]] && echo pmap-sandbox.app || echo pmap.app)}"
[[ "$APP" == *.app && "$APP" != /* && "$APP" != *..* ]] || { echo 'Output must be a relative .app path' >&2; exit 1; }
BUILD_DIR=".build-app"
mkdir -p "$BUILD_DIR" .build/module-cache
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/module-cache}"
FLAGS=(-swift-version 6)
PLUGIN="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib"
if [[ -f "$PLUGIN" ]]; then FLAGS+=(-load-plugin-library "$PLUGIN"); fi
if [[ "$SANDBOX" == 1 ]]; then FLAGS+=(-D PMAP_SANDBOX); fi
if [[ -n "${PMAP_TEST_FIXTURE:-}" ]]; then FLAGS+=(-D PMAP_TEST_HARNESS); fi
SOURCES=()
for src in Sources/*.swift; do
    gen="$BUILD_DIR/$(basename "$src" .swift).generated.swift"
    sed "s/__PMAP_VERSION__/$VERSION/g" "$src" > "$gen"
    SOURCES+=("$gen")
done
for ARCH in x86_64 arm64; do
    xcrun swiftc -O -parse-as-library -target "${ARCH}-apple-macos14.0" \
        -framework SwiftUI -framework AppKit -framework Combine -framework UserNotifications \
        "${FLAGS[@]}" -o "$BUILD_DIR/pmap-$ARCH" "${SOURCES[@]}"
    echo "✓ $ARCH"
done
# Stage a complete bundle before replacing an existing output.
STAGE="$BUILD_DIR/stage.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
lipo -create "$BUILD_DIR/pmap-x86_64" "$BUILD_DIR/pmap-arm64" -output "$STAGE/Contents/MacOS/pmap"
./make_icon.sh
cp .build/icon/AppIcon.icns "$STAGE/Contents/Resources/"
cp docs/PRIVACY.md "$STAGE/Contents/Resources/"
if [[ -n "${PMAP_TEST_FIXTURE:-}" ]]; then
    mkdir -p "$STAGE/Contents/Resources/TestFixture"
    cp "$PMAP_TEST_FIXTURE/client_key" "$PMAP_TEST_FIXTURE/known_hosts" "$STAGE/Contents/Resources/TestFixture/"
fi
python3 - "$VERSION" "$BUILD_NUMBER" "$STAGE" "$SANDBOX" <<'PY'
import os, plistlib, sys
version, build, stage, sandbox = sys.argv[1:]
with open('Resources/Info.plist', 'rb') as f: info = plistlib.load(f)
info.update(CFBundleExecutable='pmap', CFBundleIdentifier='dev.local.pmap.sandbox' if sandbox == '1' else 'dev.local.pmap',
            CFBundleVersion=build, CFBundleShortVersionString=version, LSMinimumSystemVersion='14.0')
info['PmapPrivacyPolicyURL'] = os.environ.get('PMAP_PRIVACY_POLICY_URL', '')
with open(stage + '/Contents/Info.plist', 'wb') as f: plistlib.dump(info, f)
PY
if [[ "$SANDBOX" == 1 ]]; then
    codesign --force --sign "${PMAP_SIGN_IDENTITY:--}" --entitlements Config/Pmap.entitlements "$STAGE"
else
    codesign --force --sign "${PMAP_SIGN_IDENTITY:--}" "$STAGE"
fi
codesign --verify --strict "$STAGE"
# Refuse to replace a running bundle.
if /usr/bin/pgrep -f "$PWD/$APP/Contents/MacOS/pmap" >/dev/null 2>&1; then
    echo "Quit $APP before replacing it" >&2; exit 1
fi
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "✓ $PWD/$APP (version $VERSION, build $BUILD_NUMBER, sandbox $SANDBOX)"
