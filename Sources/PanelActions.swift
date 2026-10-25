import SwiftUI
import AppKit

@MainActor
enum PanelActions {
    private static var presenting = false

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

    static func chooseConfiguration(_ store: Store) { present { chooseConfigurationNow(store) } }
    static func authorize(_ store: Store, target: URL? = nil) { present { authorizeNow(store, target: target) } }
    static func connect(_ host: String, store: Store) { present { connectNow(host, store: store) } }
    static func importLegacy(_ store: Store) { present { importLegacyNow(store) } }
    static func reset(_ store: Store) { present { resetNow(store) } }
    static func show(_ key: L10n.Key, body: L10n.Key, store: Store) { present { showNow(key, body: body, store: store) } }

    private static func chooseConfigurationNow(_ store: Store) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = store.configurationURL.deletingLastPathComponent()
        panel.message = store.t(.chooseConfig)
        if panel.runModal() == .OK, let file = panel.url { store.selectConfiguration(file) }
    }

    private static func authorizeNow(_ store: Store, target: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = target == nil
        panel.showsHiddenFiles = true
        panel.directoryURL = target?.deletingLastPathComponent() ?? AppPaths.sshHome.appendingPathComponent(".ssh")
        panel.message = store.t(.authorize)
        if let target { panel.nameFieldStringValue = target.lastPathComponent }
        guard panel.runModal() == .OK else { return }
        let host = store.activeHost
        store.disconnect(clearDesired: false)
        store.grantAccess(panel.urls, sshFolder: false)
        if let host, store.canConnect { store.selectHost(host, restore: true) }
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
        alert.addButton(withTitle: store.t(.resetConfirm))
        alert.addButton(withTitle: store.t(.cancelAction))
        if alert.runModal() == .alertFirstButtonReturn { store.revokeAccess() }
    }

    private static func showNow(_ key: L10n.Key, body: L10n.Key, store: Store) {
        let alert = NSAlert()
        alert.messageText = store.t(key)
        alert.informativeText = store.t(body)
        alert.addButton(withTitle: store.t(.done))
        alert.runModal()
    }

    static func verifyInTerminal(_ store: Store) {
        guard let host = store.activeHost, SSHConfig.isSafeAlias(host) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ssh -F \(Shell.quoted(store.sshConfigPath)) -- \(Shell.quoted(host))", forType: .string)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    static func copyDiagnostics(_ store: Store) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.redactedDiagnostics, forType: .string)
    }
}

struct PanelOptions: View {
    @ObservedObject var store: Store
    private func preference(_ path: WritableKeyPath<Config, Bool>) -> Binding<Bool> {
        Binding(get: { store.config[keyPath: path] }, set: {
            store.config[keyPath: path] = $0
            if path == \Config.autoReconnect { store.retryPreferenceChanged() }
            store.save()
        })
    }
    var body: some View {
        Menu {
            Button(store.t(.chooseConfig)) { PanelActions.chooseConfiguration(store) }
            Button(store.t(.importLegacy)) { PanelActions.importLegacy(store) }
            Divider()
            Toggle(store.t(.restoreOnLaunch), isOn: preference(\Config.restoreOnLaunch))
            Toggle(store.t(.autoReconnect), isOn: preference(\Config.autoReconnect))
            Toggle(store.t(.notificationsSetting), isOn: Binding(get: { store.config.notifications }, set: { store.setNotifications($0) }))
            Divider()
            Button(store.t(.resetAccess)) { PanelActions.reset(store) }
            if store.hasErrors {
                Button(store.t(.copyDiagnostics)) { PanelActions.copyDiagnostics(store) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.t(.options))
        .accessibilityLabel(store.t(.options))
    }
}

struct PanelAbout: View {
    @ObservedObject var store: Store
    let version: String
    var body: some View {
        Menu {
            Button(store.t(.openHomepage)) {
                NSWorkspace.shared.open(URL(string: "https://github.com/jiyeqian/pmap")!)
            }
            Button(store.t(.help)) { PanelActions.show(.help, body: .helpBody, store: store) }
            Button(store.t(.privacy)) {
                if let value = Bundle.main.object(forInfoDictionaryKey: "PmapPrivacyPolicyURL") as? String,
                   let url = URL(string: value), url.scheme == "https" { NSWorkspace.shared.open(url) }
                else { PanelActions.show(.privacy, body: .privacyText, store: store) }
            }
        } label: {
            Text(version).font(.system(size: 11, design: .monospaced))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.t(.about))
        .accessibilityLabel(store.t(.about) + " " + version)
    }
}
