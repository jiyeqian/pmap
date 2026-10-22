import Foundation
import Combine

@MainActor
final class Store: ObservableObject {
    static var shared: Store?
    @Published var config = Config()
    @Published var hostState: [String: HostConn] = [:]
    @Published var activeHost: String?
    @Published var active: Set<Int> = []
    @Published var desired: Set<Int> = []
    @Published var adhoc: [Rule] = []
    @Published var errors: [Int: PortError] = [:]
    @Published var hostError: PortError?
    @Published var storageIssue = false
    @Published var accessIssue = false
    @Published private(set) var configIssue: ConfigReadIssue?
    @Published var quickInput = ""
    @Published var inputInvalid: InputIssue?
    @Published private(set) var lang = Lang.system
    @Published var hostAliases: [String] = []
    @Published var pending: Set<Int> = []
    private var generation = UUID()
    private var session: (any TunnelBackend)?
    private var sessions: [UUID: any TunnelBackend] = [:]
    private var connectionTask: Task<Void, Never>?
    private var portTasks: [Int: Task<Void, Never>] = [:]
    private var portTokens: [Int: UUID] = [:]
    private var scopedURLs: [URL] = []
    private var stopping = false
    private var configReadable = true
    private let url: URL
    private let factory: @Sendable (String, String) -> any TunnelBackend
    private let retryDelay: Duration
    private let scansConfiguration: Bool

    init(url: URL = AppPaths.config, scanHosts: Bool = true, retryDelay: Duration = .seconds(3),
         factory: @escaping @Sendable (String, String) -> any TunnelBackend = { SSHSession(host: $0, configPath: $1) }) {
        self.url = url
        self.scansConfiguration = scanHosts
        self.factory = factory
        self.retryDelay = retryDelay
        do { config = try ConfigurationFile.load(url) }
        catch { storageIssue = true; configReadable = false }
        lang = config.lang.flatMap(Lang.init(rawValue:)) ?? .system
        adhoc = config.adhoc ?? []
        desired = Set(config.active ?? []).intersection(Set(allRules.map(\.local)))
        if scanHosts { restoreAccess(); refreshHosts() }
    }

    var busy: Bool { !pending.isEmpty }
    var hiddenHosts: Set<String> { Set(config.hiddenHosts ?? []) }
    var visibleHosts: [String] { hostAliases.filter { !hiddenHosts.contains($0) } }
    var allRules: [Rule] { config.groups.flatMap(\.rules) + adhoc }
    var onCount: Int { active.count }
    var sshDirectory: URL { URL(fileURLWithPath: config.sshDirectory ?? AppPaths.sshHome.appendingPathComponent(".ssh").path) }
    var configurationURL: URL {
        URL(fileURLWithPath: config.sshConfigFile ?? sshDirectory.appendingPathComponent("config").path).standardizedFileURL
    }
    var sshConfigPath: String { configurationURL.path }
    var canConnect: Bool { config.trustedConfig && configIssue == nil && configReadable }
    var hasErrors: Bool { storageIssue || configIssue != nil || hostError != nil || !errors.isEmpty }
    func refreshOnOpen() { if scansConfiguration { refreshHosts() } }
    func selectConfiguration(_ file: URL) {
        disconnect()
        config.sshConfigFile = file.standardizedFileURL.path
        config.sshDirectory = nil
        config.trustedConfig = false
        grantAccess([file], sshFolder: false)
    }
    func confirmConfigurationTrust() { config.trustedConfig = true; save() }


    func t(_ key: L10n.Key) -> String { L10n.text(key, lang) }
    func setLang(_ value: Lang, persist: Bool = true) {
        lang = value
        if persist { config.lang = value.rawValue; save() }
    }
    func toggleLang() { setLang(lang.other) }
    func save() {
        guard configReadable else { return } // Never overwrite a damaged/newer config with defaults.
        config.adhoc = adhoc
        config.active = desired.sorted()
        do { try ConfigurationFile.save(config, to: url); storageIssue = false }
        catch { storageIssue = true }
    }
    func refreshHosts() {
        if AppPaths.isSandboxed && scopedURLs.isEmpty {
            configIssue = .access(configurationURL.resolvingSymlinksInPath())
            accessIssue = true
            hostAliases = []
            return
        }
        do {
            hostAliases = try SSHConfig.readHosts(at: configurationURL)
            configIssue = nil
            accessIssue = false
            for host in hostAliases where hostState[host] == nil { hostState[host] = .off }
        } catch {
            configIssue = (error as? ConfigReadIssue) ?? .invalid(configurationURL)
            accessIssue = true
            hostAliases = []
        }
    }
    private func restoreAccess() {
        guard AppPaths.isSandboxed else { return }
        for data in config.bookmarks {
            do {
                var stale = false
                let target = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
                guard target.startAccessingSecurityScopedResource() else { accessIssue = true; continue }
                scopedURLs.append(target)
                if stale {
                    let renewed = try target.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                         includingResourceValuesForKeys: nil, relativeTo: nil)
                    if let index = config.bookmarks.firstIndex(of: data) { config.bookmarks[index] = renewed }
                    save()
                }
            } catch { accessIssue = true }
        }
        if AppPaths.isSandboxed && scopedURLs.isEmpty { accessIssue = true }
    }
    func grantAccess(_ targets: [URL], sshFolder: Bool) {
        // Authorization changes are only applied after disconnecting the old session.
        guard activeHost == nil else { return }
        if !AppPaths.isSandboxed {
            if sshFolder, let target = targets.first { config.sshDirectory = target.path }
            accessIssue = false
            save()
            refreshHosts()
            return
        }
        do {
            var bookmarks: [Data] = []
            let authorized = scopedURLs + targets.filter { !scopedURLs.contains($0) }
            for target in authorized {
                let data = try target.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
                if !scopedURLs.contains(target) {
                    _ = target.startAccessingSecurityScopedResource()
                    scopedURLs.append(target)
                }
                bookmarks.append(data)
            }
            config.bookmarks = bookmarks
            if sshFolder, let target = targets.first { config.sshDirectory = target.path }
            accessIssue = false
            save()
            refreshHosts()
        } catch {
            accessIssue = true
            configIssue = .access(targets.first ?? configurationURL)
        }
    }
    var redactedDiagnostics: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return "pmap \(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nSandbox: \(AppPaths.isSandboxed)\nHosts: \(hostAliases.count)\nRules: \(allRules.count)\nDesired: \(desired.count)\nActive: \(active.count)\nPending: \(pending.count)\nStorage error: \(storageIssue)\nAccess error: \(accessIssue)\n"
    }
    func revokeAccess() {
        disconnect()
        // Clear state immediately; delayed cleanup must not revoke a newly selected file.
        let oldSessions = Array(sessions.values)
        let oldURLs = scopedURLs
        scopedURLs.removeAll()
        config.bookmarks.removeAll()
        config.sshDirectory = nil
        config.sshConfigFile = nil
        config.trustedConfig = false
        accessIssue = AppPaths.isSandboxed
        configIssue = AppPaths.isSandboxed ? .access(configurationURL) : nil
        hostAliases.removeAll()
        save()
        Task {
            for backend in oldSessions { await backend.shutdown() }
            for target in oldURLs { target.stopAccessingSecurityScopedResource() }
        }
    }
    func autoConnectIfNeeded() {
        guard config.restoreOnLaunch, canConnect, !config.host.isEmpty, visibleHosts.contains(config.host) else { return }
        selectHost(config.host, restore: true)
    }
    func portLight(_ rule: Rule) -> PortLight {
        guard let host = activeHost, hostState[host] == .on else { return .gray }
        if errors[rule.local] != nil { return .red }
        return active.contains(rule.local) ? .green : .gray
    }
    func error(_ rule: Rule) -> PortError? { errors[rule.local] }
    func hostStatusText(_ host: String) -> String {
        let key: L10n.Key = switch hostState[host] ?? .off {
        case .off: .hostOff
        case .connecting: .hostConnecting
        case .on: .hostOn
        case .failed: .hostFailed
        }
        return t(key)
    }
    private func valid(_ id: UUID, _ host: String) -> Bool {
        !stopping && generation == id && activeHost == host && !Task.isCancelled
    }
    func selectHost(_ host: String, restore: Bool = false) {
        guard !stopping, canConnect, visibleHosts.contains(host), SSHConfig.isSafeAlias(host) else { return }
        if activeHost == host, hostState[host] == .on { return }
        disconnect(clearDesired: !restore)
        let id = UUID()
        generation = id
        activeHost = host
        config.host = host
        hostError = nil
        save()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            var delay = self.retryDelay
            var firstAttempt = true
            while self.valid(id, host) {
                guard firstAttempt || self.config.autoReconnect else { break }
                firstAttempt = false
                let backend = self.factory(host, self.sshConfigPath)
                self.session = backend
                self.sessions[id] = backend
                self.hostState[host] = .connecting
                let failure = await backend.connect()
                guard self.valid(id, host) else { await backend.shutdown(); return }
                if let failure {
                    self.hostError = failure
                    self.hostState[host] = .failed
                    await backend.shutdown()
                    self.sessions[id] = nil
                    guard self.config.autoReconnect, Self.retryable(failure) else { break }
                    do { try await Task.sleep(for: delay) } catch { break }
                    delay = min(delay * 2, .seconds(30))
                    continue
                }
                self.hostError = nil
                self.hostState[host] = .on
                for rule in self.allRules where self.desired.contains(rule.local) { self.scheduleOpen(rule) }
                while self.valid(id, host) {
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                    let alive = await backend.check()
                    guard self.valid(id, host) else { break }
                    if !alive { break }
                }
                guard self.valid(id, host) else { await backend.shutdown(); return }
                self.active.removeAll()
                self.cancelPortTasks()
                self.hostError = .noControlConnection
                self.hostState[host] = .failed
                await backend.shutdown()
                self.sessions[id] = nil
                if self.config.notifications {
                    Notifier.post(title: self.t(.notifyDisconnected), body: self.t(.connectionLost))
                }
                guard self.config.autoReconnect else { break }
                do { try await Task.sleep(for: self.retryDelay) } catch { break }
            }
        }
    }
    static func retryable(_ error: PortError) -> Bool {
        switch error {
        case .authFailed, .fileAccess, .tooManyAuthFailures, .hostKeyRejected, .forwardingNotAllowed, .handshakeFailed: false
        default: true
        }
    }
    private func cancelPortTasks() {
        for task in portTasks.values { task.cancel() }
        portTasks.removeAll()
        portTokens.removeAll()
        pending.removeAll()
    }
    func disconnect(clearDesired: Bool = true) {
        let oldID = generation
        generation = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        cancelPortTasks()
        if let host = activeHost { hostState[host] = .off }
        activeHost = nil
        active.removeAll()
        errors.removeAll()
        hostError = nil
        if clearDesired { desired.removeAll(); save() }
        if let old = session {
            session = nil
            // Keep a reference until cleanup completes so quit can also await it.
            Task { await old.shutdown(); sessions[oldID] = nil }
        }
    }
    func shutdownAll() async {
        stopping = true
        save()
        connectionTask?.cancel()
        cancelPortTasks()
        let all = Array(sessions.values)
        await withTaskGroup(of: Void.self) { group in
            for backend in all { group.addTask { await backend.shutdown() } }
        }
        sessions.removeAll()
        session = nil
        active.removeAll()
        activeHost = nil
    }
    func retryPreferenceChanged() {
        guard config.autoReconnect else { return }
        if let host = activeHost, hostState[host] == .failed { selectHost(host, restore: true) }
        else {
            for rule in allRules where desired.contains(rule.local) { scheduleOpen(rule) }
        }
    }
    func toggle(_ rule: Rule) {
        if desired.contains(rule.local) || active.contains(rule.local) { close(rule) }
        else { open(rule) }
    }
    func open(_ rule: Rule) {
        guard activeHost != nil, allRules.contains(rule) else { return }
        desired.insert(rule.local)
        save()
        scheduleOpen(rule)
    }
    private func scheduleOpen(_ rule: Rule) {
        guard let backend = session, let host = activeHost, hostState[host] == .on,
              portTasks[rule.local] == nil, !active.contains(rule.local) else { return }
        let id = generation
        let token = UUID()
        portTokens[rule.local] = token
        pending.insert(rule.local)
        portTasks[rule.local] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.portTokens[rule.local] == token {
                    self.portTasks[rule.local] = nil
                    self.pending.remove(rule.local)
                }
            }
            var delay: Duration = .seconds(5)
            var firstAttempt = true
            while self.valid(id, host), self.desired.contains(rule.local), self.allRules.contains(rule) {
                guard firstAttempt || self.config.autoReconnect else { return }
                firstAttempt = false
                let failure = await backend.forward(rule)
                guard self.valid(id, host), self.portTokens[rule.local] == token,
                      self.desired.contains(rule.local), self.allRules.contains(rule) else {
                    let cleanupError = await Task.detached { await backend.cancel(rule) }.value
                    if self.generation == id, let cleanupError {
                        self.active.insert(rule.local)
                        self.errors[rule.local] = cleanupError
                    }
                    return
                }
                self.errors[rule.local] = failure
                if failure == nil { self.active.insert(rule.local); return }
                guard self.config.autoReconnect, let failure, Self.retryable(failure) else { return }
                do { try await Task.sleep(for: delay) } catch { return }
                delay = min(delay * 2, .seconds(30))
            }
        }
    }
    func close(_ rule: Rule, remove: Bool = false) {
        desired.remove(rule.local)
        save()
        let previous = portTasks[rule.local]
        previous?.cancel()
        let token = UUID()
        portTokens[rule.local] = token
        pending.insert(rule.local)
        let id = generation
        let backend = session
        portTasks[rule.local] = Task { [weak self] in
            // Finish stale forward cleanup before allowing another operation on this port.
            await previous?.value
            guard let self, self.generation == id else { return }
            let failure = self.active.contains(rule.local) ? await backend?.cancel(rule) : nil
            guard self.generation == id, self.portTokens[rule.local] == token else { return }
            self.pending.remove(rule.local)
            self.portTasks[rule.local] = nil
            if let failure { self.errors[rule.local] = failure; return }
            self.active.remove(rule.local)
            self.errors[rule.local] = nil
            if remove { self.removeStoredRule(rule) }
        }
    }
    func commitQuick() {
        guard let (rule, _) = parseQuickInput(quickInput) else {
            quickInput = ""; inputInvalid = .badFormat; return
        }
        guard !allRules.contains(where: { $0.local == rule.local }) else {
            quickInput = ""; inputInvalid = .duplicatedPort; return
        }
        adhoc.append(rule)
        quickInput = ""
        inputInvalid = nil
        save()
        if activeHost != nil { open(rule) }
    }
    func removeRuleAnywhere(_ rule: Rule) { close(rule, remove: true) }
    private func removeStoredRule(_ rule: Rule) {
        for i in config.groups.indices { config.groups[i].rules.removeAll { $0.local == rule.local } }
        config.groups.removeAll { $0.rules.isEmpty }
        adhoc.removeAll { $0.local == rule.local }
        save()
    }
}
