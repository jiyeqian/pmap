// IconDrawing.swift
// 共享图标绘制模块 —— App 图标与状态栏图标同源的 glyph
//
// 概念：port:port 抽象为「p + 镜像 p（上下翻转）」，绕中心 180° 旋转对称：
//       一个居中大圆环 + 一个居中圆点，左竖笔（p）向下、右竖笔（倒 p）向上，共享圆心。
//
// 几何参数来自用户上传的 pmap_06（Pixelmator 512×512 SVG）归一化而来，
// 颜色全部参数化：App 图标与状态栏图标共用同一套几何，仅圆点颜色不同。
// 集中在本文件的 PmapIconGeometry / PmapColors 中，方便后续微调。

import AppKit

/// 图标几何参数（归一化到画布边长，1.0 表示一整条边长；AppKit 坐标，y 向上）
enum PmapIconGeometry {
    static let ringCX: CGFloat = 0.5006   // 圆环圆心 x
    static let ringCY: CGFloat = 0.5003   // 圆环圆心 y
    static let ringR: CGFloat = 0.3125    // 圆环半径

    static let dotCX: CGFloat = 0.5000    // 圆点圆心 x（≈ 与圆环同心）
    static let dotCY: CGFloat = 0.4999    // 圆点圆心 y
    static let dotR: CGFloat = 0.2500     // 圆点半径

    static let stemW: CGFloat = 0.1719    // 胶囊竖笔宽

    static let leftStemX: CGFloat = 0.2736
    static let leftStemYBottom: CGFloat = 0.1261
    static let leftStemYTop: CGFloat = 0.5558

    static let rightStemX: CGFloat = 0.7267
    static let rightStemYBottom: CGFloat = 0.4434
    static let rightStemYTop: CGFloat = 0.8730
}

/// 图标配色（绿/红统一为系统色，与面板端口圆点、主机状态文字一致）
enum PmapColors {
    static let green = NSColor.systemGreen   // 圆点：正常/连通（#30D158）
    static let red = NSColor.systemRed       // 圆点：故障（#FF4245）
    static let idleGray = NSColor.systemGray // 圆点：空闲/未连接（系统灰，与绿/红同一取色方式）
    static let bg = NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.18, alpha: 1) // #2B2B2E
}

private func circleRect(cx: CGFloat, cy: CGFloat, r: CGFloat) -> NSRect {
    NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
}

/// 核心绘制：在 size×size 的正方形画布（原点 (0,0)）内绘制 glyph。
/// 绘制顺序与 SVG 一致：两条胶囊竖笔 → 圆环 → 圆点（圆点最上层，完整显示）。
/// 依赖当前 NSGraphicsContext 已就绪（App 图标走 lockFocus，状态栏走 bitmap context）。
func drawPmapGlyph(size: CGFloat, ringColor: NSColor, dotColor: NSColor) {
    let s = size
    let g = PmapIconGeometry.self

    // 两条胶囊竖笔（圆角矩形，圆角 = 宽/2，全圆头）
    ringColor.setFill()
    let stemR = g.stemW * s / 2
    let leftStem = NSRect(x: g.leftStemX * s - stemR,
                          y: g.leftStemYBottom * s,
                          width: g.stemW * s,
                          height: (g.leftStemYTop - g.leftStemYBottom) * s)
    let rightStem = NSRect(x: g.rightStemX * s - stemR,
                           y: g.rightStemYBottom * s,
                           width: g.stemW * s,
                           height: (g.rightStemYTop - g.rightStemYBottom) * s)
    NSBezierPath(roundedRect: leftStem, xRadius: stemR, yRadius: stemR).fill()
    NSBezierPath(roundedRect: rightStem, xRadius: stemR, yRadius: stemR).fill()

    // 圆环（实心圆）
    ringColor.setFill()
    NSBezierPath(ovalIn: circleRect(cx: g.ringCX * s, cy: g.ringCY * s, r: g.ringR * s)).fill()

    // 圆点（最上层，完整显示）
    dotColor.setFill()
    NSBezierPath(ovalIn: circleRect(cx: g.dotCX * s, cy: g.dotCY * s, r: g.dotR * s)).fill()
}

/// App 图标：深灰黑 squircle 背景 + 白环白竖笔 + 绿色圆点
/// macOS 11+ 图标规范：圆角（squircle）由图标自身绘制，系统不再自动裁；
/// 圆角矩形近似半径 = 22.37% 边长（Apple squircle 等效值），圆角外为透明。
func pmapAppIcon(size: CGFloat = 1024) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let squircle = NSBezierPath(roundedRect: rect,
                                xRadius: size * 0.2237,
                                yRadius: size * 0.2237)
    PmapColors.bg.setFill()
    squircle.fill()
    squircle.addClip()   // glyph 裁剪在 squircle 内，圆角外透明

    drawPmapGlyph(size: size, ringColor: .white, dotColor: PmapColors.green)
    return image
}

/// 状态栏图标：透明背景 + 参数化颜色（非 template，动态染色）
func pmapStatusBarIcon(ringColor: NSColor, dotColor: NSColor,
                       points: CGFloat = 18, scale: CGFloat = 2) -> NSImage {
    let pixels = Int(points * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        return NSImage()
    }
    rep.size = NSSize(width: points, height: points)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawPmapGlyph(size: points, ringColor: ringColor, dotColor: dotColor)
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: points, height: points))
    image.addRepresentation(rep)
    image.isTemplate = false
    return image
}
