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

// 背景：macOS 图标是带圆角的方形，这里画满格（系统会自动裁圆角）
// 深灰黑单色背景（Apple HIG 深色图标常用 #2C2C2E，克制、无渐变）
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgColor = NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
bgColor.setFill()
ctx.fill(bgRect)

// 主体：白色双向箭头（与状态栏同一 SF Symbol，medium 字重，居中）
// SF Symbol 默认是黑色模板图，需用 sourceAtop 蒙版技法染成白色
if let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.48, weight: .medium)
    if let configured = symbol.withSymbolConfiguration(config) {
        // 先画符号作为蒙版（黑箭头 + 透明底）
        let tinted = NSImage(size: configured.size)
        tinted.lockFocus()
        let tctx = NSGraphicsContext.current!.cgContext
        configured.draw(in: NSRect(origin: .zero, size: configured.size))
        tctx.setBlendMode(.sourceAtop)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: configured.size).fill()
        tinted.unlockFocus()

        let origin = NSPoint(x: (size - configured.size.width) / 2,
                             y: (size - configured.size.height) / 2)
        tinted.draw(in: NSRect(origin: origin, size: configured.size),
                    from: NSRect(origin: .zero, size: configured.size),
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
