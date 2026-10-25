import SwiftUI
import AppKit

@MainActor
enum PanelActions {
    private static var presenting = false
    static var restoreMainPanel: (@MainActor () -> Void)?

    // Native dialogs must start after SwiftUI's menu tracking has ended.
    private static func present(_ action: @escaping @MainActor () -> Void) {
        guard !presenting else { return }
        presenting = true
        DispatchQueue.main.async {
            defer { presenting = false }
            NSApp.activate(ignoringOtherApps: true)
            action()
        }
    }

    static func chooseSSHDirectory(_ store: Store) { present { chooseSSHDirectoryNow(store) } }
    static func authorize(_ store: Store, target: URL? = nil) { present { authorizeNow(store, target: target) } }
    static func connect(_ host: String, store: Store) { present { connectNow(host, store: store) } }
    static func importLegacy(_ store: Store) { present { importLegacyNow(store) } }
    static func information(_ store: Store) { present { showTextNow(.runtimeInformation, text: store.redactedDiagnostics, store: store) } }
    static func reset(_ store: Store) { present { resetNow(store) } }
    static func show(_ key: L10n.Key, body: L10n.Key, store: Store) { present { showNow(key, body: body, store: store) } }

    private static func chooseSSHDirectoryNow(_ store: Store) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = store.sshRoot
        panel.prompt = store.t(.allowAccess)
        panel.message = store.t(.authorizeSSHDirectory)
        panel.begin { response in
            panel.orderOut(nil)
            guard response == .OK, let directory = panel.url else { restoreMainPanel?(); return }
            guard store.selectSSHDirectory(directory) else {
                message(store.t(.chooseSSHDirectoryOnly), store: store)
                return
            }
            continueAuthorization(store, attempted: [])
        }
    }

    static func continueAuthorization(_ store: Store, attempted: Set<URL> = []) {
        if let request = store.supplementalAccess, !attempted.contains(request.target) {
            authorizeNow(store, target: request.target, messageKey: request.message, attempted: attempted.union([request.target]))
        } else if let message = store.configMessage {
            self.message(message, store: store)
        } else if let message = store.knownHostsMessage {
            self.message(message, store: store)
        } else { restoreMainPanel?() }
    }

    private static func authorizeNow(_ store: Store, target: URL?, messageKey: L10n.Key? = nil, attempted: Set<URL> = []) {
        guard let requested = target ?? store.requiredFileAccess?.target else { return }
        let target = SSHConfig.realTarget(requested)
        let panel = NSOpenPanel()
        panel.canChooseFiles = !target.hasDirectoryPath
        panel.canChooseDirectories = target.hasDirectoryPath
        panel.showsHiddenFiles = true
        panel.directoryURL = target.deletingLastPathComponent()
        panel.nameFieldStringValue = target.lastPathComponent
        panel.prompt = store.t(.allowAccess)
        panel.message = store.t(messageKey ?? store.requiredFileAccess?.message ?? .authorize)
        panel.begin { response in
            panel.orderOut(nil)
            guard response == .OK, let file = panel.url else { restoreMainPanel?(); return }
            guard file.resolvingSymlinksInPath() == target else {
                message(store.t(.authorize), store: store)
                return
            }
            let host = store.activeHost
            store.disconnect(clearDesired: false)
            store.grantAccess([file], sshFolder: false)
            if let host, store.canConnect { store.selectHost(host, restore: true) }
            continueAuthorization(store, attempted: attempted.union([target]))
        }
    }

    private static func message(_ text: String, store: Store) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: store.t(.done))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { _ in alert.window.orderOut(nil); restoreMainPanel?() }
        } else {
            alert.runModal()
            restoreMainPanel?()
        }
    }

    private static func connectNow(_ host: String, store: Store) {
        if !store.config.trustedConfig {
            let alert = NSAlert()
            alert.messageText = store.t(.configTrust)
            alert.informativeText = store.t(.configTrustBody)
            alert.addButton(withTitle: store.t(.connectConfirm))
            alert.addButton(withTitle: store.t(.cancelAction))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.confirmConfigurationTrust()
        }
        store.selectHost(host, restore: store.shouldRestoreSelection(host))
    }

    private static func importLegacyNow(_ store: Store) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = AppPaths.sshHome.appendingPathComponent("Library/Application Support/Pmap")
        panel.message = store.t(.importLegacy)
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let file = panel.url else { return }
            confirmImport(file, store: store, parent: parent)
        }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private static func confirmImport(_ file: URL, store: Store, parent: NSWindow?) {
        let accessing = file.startAccessingSecurityScopedResource()
        let alert = NSAlert()
        alert.messageText = store.t(.importTitle)
        alert.informativeText = store.t(.importBody)
        alert.addButton(withTitle: store.t(.importConfirm))
        alert.addButton(withTitle: store.t(.cancelAction))
        let completion: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            defer { if accessing { file.stopAccessingSecurityScopedResource() } }
            guard response == .alertFirstButtonReturn else { return }
            do { try store.importLegacyConfiguration(file) }
            catch {
                let failure = NSAlert()
                failure.messageText = store.t(.importFailed)
                failure.addButton(withTitle: store.t(.done))
                if let parent { failure.beginSheetModal(for: parent) }
                else { failure.runModal() }
            }
        }
        if let parent { alert.beginSheetModal(for: parent, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    private static func resetNow(_ store: Store) {
        let alert = NSAlert()
        alert.messageText = store.t(.resetTitle)
        alert.informativeText = store.t(.resetBody)
        alert.addButton(withTitle: store.t(.cancelAction)).keyEquivalent = "\r"
        alert.addButton(withTitle: store.t(.resetConfirm)).keyEquivalent = ""
        if alert.runModal() == .alertSecondButtonReturn { store.revokeAccess(); restoreMainPanel?() }
    }

    private static func showNow(_ key: L10n.Key, body: L10n.Key, store: Store) {
        showTextNow(key, text: store.t(body), store: store)
    }

    private static func showTextNow(_ key: L10n.Key, text: String, store: Store) {
        let alert = NSAlert()
        alert.messageText = store.t(key)
        alert.addButton(withTitle: store.t(.closeInformation))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: key == .runtimeInformation ? 320 : 120))
        scroll.hasVerticalScroller = true
        let content = NSTextView(frame: scroll.bounds)
        content.isEditable = false
        content.isSelectable = true
        content.drawsBackground = false
        content.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        content.textColor = .labelColor
        content.textContainerInset = NSSize(width: 0, height: 4)
        content.isVerticallyResizable = true
        content.isHorizontallyResizable = false
        content.autoresizingMask = [.width]
        content.textContainer?.widthTracksTextView = true
        content.string = text
        content.setSelectedRange(NSRange(location: 0, length: 0))
        scroll.documentView = content
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = content
        alert.runModal()
    }

    static func verifyInTerminal(_ store: Store) {
        guard let host = store.activeHost ?? (store.visibleHosts.contains(store.config.host) ? store.config.host : store.visibleHosts.first),
              SSHConfig.isSafeAlias(host) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ssh -F \(Shell.quoted(store.sshConfigPath)) -- \(Shell.quoted(host))", forType: .string)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

struct PanelOptions: View {
    @ObservedObject var store: Store

    var body: some View {
        Menu {
            Button(store.lang == .zh ? "English" : "简体中文") { store.toggleLang() }
            Button(store.t(.resetAccess)) { PanelActions.reset(store) }
            Divider()
            Button(store.t(.runtimeInformation)) { PanelActions.information(store) }
            Button(store.t(.help)) {
                NSWorkspace.shared.open(URL(string: "https://github.com/jiyeqian/pmap")!)
            }
            Button(store.t(.privacy)) { PanelActions.show(.privacy, body: .privacyText, store: store) }
        } label: {
            Image(systemName: "ellipsis").frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.t(.options))
        .accessibilityLabel(store.t(.options))
    }
}
