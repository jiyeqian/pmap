#!/bin/bash
# 生成 pmap.app 的应用图标（AppIcon.icns）
# 用法：./make_icon.sh  （需要 macOS，使用内置 Swift + CoreGraphics 绘制）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p .build/module-cache
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/module-cache}"

OUT_DIR=".build/icon"
mkdir -p "$OUT_DIR/AppIcon.iconset"

# 精简入口：调用共享绘制模块 Sources/IconDrawing.swift 的 pmapAppIcon()
# （pq 门形 glyph，与状态栏图标 100% 同源）
cat > "$OUT_DIR/draw.swift" <<'EOF'
import AppKit

@main
struct DrawIcon {
    static func main() {
        let image = pmapAppIcon(size: 1024)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败"); exit(1)
        }
        try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
EOF

xcrun swiftc -parse-as-library -O "$SCRIPT_DIR/Sources/IconDrawing.swift" "$OUT_DIR/draw.swift" -o "$OUT_DIR/draw"
"$OUT_DIR/draw" "$OUT_DIR/icon_1024.png"

# 生成 iconset 各尺寸
cd "$OUT_DIR"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  sz=$(echo $spec | cut -d' ' -f1); name=$(echo $spec | cut -d' ' -f2)
  sips -z $sz $sz icon_1024.png --out "AppIcon.iconset/${name}.png" >/dev/null 2>&1
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "✓ AppIcon.icns 已生成：$OUT_DIR/AppIcon.icns"
