import AppKit
import Foundation
import Testing
@testable import PmapCore

@Suite("品牌与状态图标")
@MainActor
struct IconDrawingTests {
    private func bitmap(_ appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        var image: NSImage?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            image = pmapAppIcon(size: 128)
        }
        return try #require(image?.representations.first as? NSBitmapImageRep)
    }

    @Test("品牌圆心为固定绿色，不随明暗主题变化")
    func fixedBrandPalette() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rep = try bitmap(appearance)
            let center = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
            #expect(abs(center.redComponent - 48.0 / 255) < 0.01, "red \(center.redComponent)")
            #expect(abs(center.greenComponent - 209.0 / 255) < 0.01, "green \(center.greenComponent)")
            #expect(abs(center.blueComponent - 88.0 / 255) < 0.01, "blue \(center.blueComponent)")
            #expect(center.alphaComponent > 0.99)
        }
    }

    @Test("README Logo由共享源生成，资产未失步")
    func generatedSVG() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let committed = try String(contentsOf: root.appendingPathComponent("docs/logo.svg"), encoding: .utf8)
        #expect(XMLParser(data: Data(committed.utf8)).parse())
        #expect(committed == pmapBrandSVG())
        #expect(committed.contains("#2B2B2E"))
        #expect(committed.contains("#FFFFFF"))
        #expect(committed.contains("#30D158"))
    }

    @Test("状态图标保留透明背景和彩色中心，不作为单色模板")
    func statusGlyph() throws {
        for ring in [NSColor.black, .white] {
            for dot in [NSColor.systemGreen, .systemRed, .systemGray] {
                let image = pmapStatusBarIcon(ringColor: ring, dotColor: dot)
                #expect(!image.isTemplate)
                #expect(image.size == NSSize(width: 18, height: 18))
                let data = try #require(image.tiffRepresentation)
                let rep = try #require(NSBitmapImageRep(data: data))
                let corner = try #require(rep.colorAt(x: 0, y: 0))
                let center = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
                #expect(corner.alphaComponent < 0.01)
                #expect(center.alphaComponent > 0.95)
                let outline = try #require(rep.colorAt(x: Int(Double(rep.pixelsWide) * 0.78), y: rep.pixelsHigh / 2))
                #expect(outline.alphaComponent > 0.8)
                let brightness = (outline.redComponent + outline.greenComponent + outline.blueComponent) / 3
                #expect(ring == .black ? brightness < 0.1 : brightness > 0.9)
            }
        }
    }
}
