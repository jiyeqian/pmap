import AppKit
import SwiftUI

@main
@MainActor
struct AppearanceProbe {
    static func main() {
        _ = NSApplication.shared
        let store = Store(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"), scanHosts: false)
        store.hostAliases = ["demo"]
        store.activeHost = "demo"
        store.hostState["demo"] = .on
        store.adhoc = [Rule(local: 8000, remote: 80, note: "demo")]
        Store.shared = store
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        guard let panel = NSApp.windows.first(where: { $0 is PanelWindow }), let content = panel.contentView else {
            fatalError("Production panel was not created")
        }
        panel.orderOut(nil)
        panel.setContentSize(content.fittingSize)
        func background(_ appearance: NSAppearance.Name) -> Double {
            panel.appearance = NSAppearance(named: appearance)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            content.layoutSubtreeIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fatalError("No bitmap") }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            // Empty area at the left edge, below the header and away from glyphs.
            let x = max(1, Int(Double(bitmap.pixelsWide) * 0.02))
            let y = max(1, Int(Double(bitmap.pixelsHigh) * 0.45))
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { fatalError("No pixel") }
            precondition(color.alphaComponent > 0.95, "Panel background must be opaque")
            precondition(!panel.isVisible, "Hidden-panel regression must stay hidden")
            return Double((color.redComponent + color.greenComponent + color.blueComponent) / 3)
        }
        let light = background(.aqua)
        let dark = background(.darkAqua)
        let lightAgain = background(.aqua)
        precondition(light > 0.8 && dark < 0.3 && lightAgain > 0.8, "Theme background did not follow appearance: \(light), \(dark), \(lightAgain)")
        print("PASS hidden production panel light/dark/light: \(light), \(dark), \(lightAgain)")
        withExtendedLifetime(delegate) {}
    }
}
