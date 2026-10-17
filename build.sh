#!/bin/bash
# 构建 pmap.app（Intel + Apple Silicon 通用）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="pmap"
BUILD_DIR=".build"
APP="${APP_NAME}.app"
BIN="${BUILD_DIR}/${APP_NAME}-univ"

rm -rf "$BUILD_DIR" "${APP}.app"
mkdir -p "$BUILD_DIR"

echo "▸ 编译通用二进制 (x86_64 + arm64)..."
for ARCH in x86_64 arm64; do
  swiftc -O -parse-as-library \
    -target ${ARCH}-apple-macos14.0 \
    -framework SwiftUI -framework AppKit -framework Combine \
    -o "${BUILD_DIR}/${APP_NAME}-${ARCH}" \
    Sources/Pmap.swift
  echo "  ✓ ${ARCH}"
done

echo "▸ 打包 app bundle..."
rm -rf "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
lipo -create "${BUILD_DIR}/${APP_NAME}-x86_64" "${BUILD_DIR}/${APP_NAME}-arm64" \
     -output "$BIN"
mv "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>pmap</string>
    <key>CFBundleDisplayName</key><string>pmap</string>
    <key>CFBundleExecutable</key><string>pmap</string>
    <key>CFBundleIdentifier</key><string>dev.local.pmap</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 签名（ad-hoc），避免 Gatekeeper 拦截
codesign --force --deep --sign - "${APP}" 2>/dev/null || true

SIZE=$(du -sh "${APP}" | cut -f1)
echo "✓ ${APP}  (${SIZE})"
echo "  拖到「应用程序」或直接 open ${APP}"
