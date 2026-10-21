import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: Store
    @State private var confirmingTrust = false

    private func preference(_ path: WritableKeyPath<Config, Bool>) -> Binding<Bool> {
        Binding(get: { store.config[keyPath: path] }, set: { value in
            store.config[keyPath: path] = value
            if path == \Config.notifications, value { Notifier.requestAuthorization() }
            if path == \Config.autoReconnect { store.retryPreferenceChanged() }
            store.save()
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(store.t(.setupTitle)).font(.title2)
                Text(store.t(.setupGuide)).textSelection(.enabled)
                if store.storageIssue { Text(store.t(.storageIssue)).foregroundStyle(.red) }
                if store.accessIssue { Text(store.t(.accessIssue)).foregroundStyle(.red) }
                Button(store.t(.selectSSHFolder)) { choose(sshFolder: true) }
                    .disabled(store.activeHost != nil)
                Button(store.t(.grantResources)) { choose(sshFolder: false) }
                    .disabled(store.activeHost != nil)
                if store.activeHost != nil { Text(store.t(.disconnectBeforeAccess)).font(.caption) }
                Button(store.t(store.config.trustedConfig ? .configTrusted : .configTrust)) { confirmingTrust = true }
                    .disabled(store.config.trustedConfig)
                Text(store.t(.settingsHint)).font(.callout).foregroundStyle(.secondary)
                Button(store.t(.refreshHosts)) { store.refreshHosts() }
                if let host = store.activeHost ?? (store.config.host.isEmpty ? nil : store.config.host), SSHConfig.isSafeAlias(host) {
                    Button(store.t(.prepareTerminal)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("ssh -F \(Shell.quoted(store.sshConfigPath)) -- \(Shell.quoted(host))", forType: .string)
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        }
                    }
                }
                Divider()
                Text(store.t(.behavior)).font(.headline)
                Toggle(store.t(.restoreOnLaunch), isOn: preference(\Config.restoreOnLaunch))
                Toggle(store.t(.autoReconnect), isOn: preference(\Config.autoReconnect))
                Toggle(store.t(.notificationsSetting), isOn: preference(\Config.notifications))
                if store.activeHost != nil { Button(store.t(.disconnect)) { store.disconnect() } }
                Button(store.t(.copyDiagnostics)) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.redactedDiagnostics, forType: .string)
                }
                Divider()
                Text(store.t(.privacy)).font(.headline)
                if let value = Bundle.main.object(forInfoDictionaryKey: "PmapPrivacyPolicyURL") as? String,
                   let url = URL(string: value), url.scheme == "https" {
                    Link(store.t(.privacy), destination: url)
                }
                Text(store.t(.privacyText)).textSelection(.enabled)
                Button(store.t(.revokeAccess)) { store.revokeAccess() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 600)
        .alert(store.t(.configTrust), isPresented: $confirmingTrust) {
            Button(store.t(.confirm)) { store.config.trustedConfig = true; store.save() }
            Button(store.t(.cancelAction), role: .cancel) {}
        } message: { Text(store.t(.configTrustBody)) }
    }
    private func choose(sshFolder: Bool) {
        guard store.activeHost == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = !sshFolder
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = !sshFolder
        panel.showsHiddenFiles = true
        panel.directoryURL = AppPaths.sshHome
        panel.message = store.t(sshFolder ? .selectSSHFolder : .grantResources)
        if panel.runModal() == .OK { store.grantAccess(panel.urls, sshFolder: sshFolder) }
    }
}
