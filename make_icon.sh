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

// 绘制 macOS 风格应用图标：深色圆角底 + 双向箭头（对应菜单栏符号 arrow.left.arrow.right）
let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext

// 背景： macOS 图标是带圆角的方形（系统会自动裁圆角，这里画满格）
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgColor = NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.18, alpha: 1)
bgColor.setFill()
ctx.fill(bgRect)

// 细微渐变提升质感
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(calibratedWhite: 0.20, alpha: 1).cgColor,
                                   NSColor(calibratedWhite: 0.10, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
ctx.saveGState()
ctx.clip(to: bgRect)
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
ctx.restoreGState()

// 中心双向箭头（↔），粗圆头线条
let stroke = NSColor(calibratedWhite: 0.95, alpha: 1)
stroke.setStroke()
let lineWidth = size * 0.07
let line = NSBezierPath()
line.lineWidth = lineWidth
line.lineCapStyle = .round
let cy = size * 0.5
let inset = size * 0.22
line.move(to: NSPoint(x: inset, y: cy))
line.line(to: NSPoint(x: size - inset, y: cy))
line.stroke()

// 左箭头头
func arrowHead(atX x: CGFloat, dirRight: Bool) {
    let head = NSBezierPath()
    head.lineWidth = lineWidth
    head.lineCapStyle = .round
    let len = size * 0.11
    let spread = size * 0.09
    let sign: CGFloat = dirRight ? 1 : -1
    head.move(to: NSPoint(x: x, y: cy))
    head.line(to: NSPoint(x: x + sign * len, y: cy + spread))
    head.move(to: NSPoint(x: x, y: cy))
    head.line(to: NSPoint(x: x + sign * len, y: cy - spread))
    head.stroke()
}
arrowHead(atX: inset, dirRight: false)   // 左端箭头（指向左）
arrowHead(atX: size - inset, dirRight: true) // 右端箭头（指向右）

// 绿色小圆点表示「连通」主题，右下角
let dot = NSBezierPath(ovalIn: CGRect(x: size * 0.74, y: size * 0.16, width: size * 0.11, height: size * 0.11))
NSColor(calibratedRed: 0.11, green: 0.62, blue: 0.46, alpha: 1).setFill()
dot.fill()

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
