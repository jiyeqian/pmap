#!/bin/bash
# 生成 pmap.app 的应用图标（AppIcon.icns）
# 用法：./make_icon.sh  （需要 macOS，使用内置 Swift + CoreGraphics 绘制）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OUT_DIR=".build/icon"
mkdir -p "$OUT_DIR/AppIcon.iconset"

cat > "$OUT_DIR/draw.swift" <<'EOF'
import AppKit
import CoreGraphics

// 用 SF Symbol 原图生成图标，与状态栏图标 100% 同源（arrow.left.arrow.right）
let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext

// 背景： macOS 图标是带圆角的方形，这里画满格（系统会自动裁圆角）
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgColor = NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.18, alpha: 1)
bgColor.setFill()
ctx.fill(bgRect)

// 直接使用 SF Symbol 的原生图形（与状态栏同一符号、同一视觉语言）
if let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.56, weight: .medium)
    if let configured = symbol.withSymbolConfiguration(config) {
        // 白色模板图
        let tinted = NSImage(size: configured.size)
        tinted.lockFocus()
        NSColor.white.set()
        configured.draw(in: NSRect(origin: .zero, size: configured.size))
        tinted.unlockFocus()

        let target = NSSize(width: size * 0.72, height: size * 0.72)
        let origin = NSPoint(x: (size - target.width) / 2, y: (size - target.height) / 2)
        tinted.draw(in: NSRect(origin: origin, size: target),
                    from: NSRect(origin: .zero, size: tinted.size),
                    operation: .sourceOver, fraction: 1.0)
    }
}

image.unlockFocus()

// 输出各尺寸 PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("渲染失败"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
EOF

xcrun swiftc -O "$OUT_DIR/draw.swift" -o "$OUT_DIR/draw" 2>/dev/null
"$OUT_DIR/draw" "$OUT_DIR/icon_1024.png"

# 生成 iconset 各尺寸
cd "$OUT_DIR"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  sz=$(echo $spec | cut -d' ' -f1); name=$(echo $spec | cut -d' ' -f2)
  sips -z $sz $sz icon_1024.png --out "AppIcon.iconset/${name}.png" >/dev/null 2>&1
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
cp AppIcon.icns "$SCRIPT_DIR/pmap.app/Contents/Resources/AppIcon.icns"
echo "✓ AppIcon.icns 已生成：$OUT_DIR/AppIcon.icns"
