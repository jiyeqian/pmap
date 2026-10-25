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
    private let heartbeatDelay: Duration
    private let portRetryDelay: Duration
    private let sendNotice: @MainActor (ConnectionNotice, Lang) -> Void
    private let requestNotifications: @MainActor () -> Void

    init(url: URL = AppPaths.config, scanHosts: Bool = true, retryDelay: Duration = .seconds(3),
         heartbeatDelay: Duration = .seconds(30), portRetryDelay: Duration = .seconds(5),
         sendNotice: @escaping @MainActor (ConnectionNotice, Lang) -> Void = { Notifier.post($0, lang: $1) },
         requestNotifications: @escaping @MainActor () -> Void = { Notifier.requestAuthorization() },
         factory: @escaping @Sendable (String, String) -> any TunnelBackend = { SSHSession(host: $0, configPath: $1) }) {
        self.url = url
        self.scansConfiguration = scanHosts
        self.factory = factory
        self.retryDelay = retryDelay
        self.heartbeatDelay = heartbeatDelay
        self.portRetryDelay = portRetryDelay
        self.sendNotice = sendNotice
        self.requestNotifications = requestNotifications
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
        // An upgrade/import awaiting its first authorization must retain saved ports.
        disconnect(clearDesired: activeHost != nil)
        config.sshConfigFile = file.standardizedFileURL.path
        config.sshDirectory = nil
        config.trustedConfig = false
        grantAccess([file], sshFolder: false)
    }
    func confirmConfigurationTrust() { config.trustedConfig = true; save() }
    var hasSavedSession: Bool {
        activeHost == nil && config.restoreOnLaunch && !config.host.isEmpty && visibleHosts.contains(config.host)
    }
    func shouldRestoreSelection(_ host: String) -> Bool {
        activeHost == host || (hasSavedSession && config.host == host)
    }
    func importLegacyConfiguration(_ file: URL) throws {
        guard configReadable else { throw CocoaError(.coderReadCorrupt) }
        // A missing import must fail, rather than being interpreted as an empty new configuration.
        _ = try Data(contentsOf: file)
        let previous = try ConfigurationFile.load(file)
        var imported = config
        imported.host = previous.host
        imported.groups = previous.groups
        imported.adhoc = previous.adhoc
        imported.active = previous.active
        imported.hiddenHosts = previous.hiddenHosts
        imported.lang = previous.lang
        // Validate and persist before disconnecting/replacing current in-memory state.
        try ConfigurationFile.save(imported, to: url)
        disconnect(clearDesired: false)
        config = imported
        adhoc = imported.adhoc ?? []
        desired = Set(imported.active ?? []).intersection(Set(allRules.map(\.local)))
        lang = imported.lang.flatMap(Lang.init(rawValue:)) ?? .system
        save()
    }
    func setNotifications(_ enabled: Bool) {
        config.notifications = enabled
        if enabled { requestNotifications() }
        save()
    }
    private func notify(_ notice: ConnectionNotice) {
        if config.notifications { sendNotice(notice, lang) }
    }


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
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let state: String = if let host = activeHost {
            switch hostState[host] ?? .off {
            case .off: "off"
            case .connecting: "connecting"
            case .on: "connected"
            case .failed: "failed"
            }
        } else { "off" }
        let configurationError: String = switch configIssue {
        case .access: "access_denied"
        case .missing: "file_missing"
        case .invalid: "unreadable_or_invalid"
        case nil: "none"
        }
        let counts = Dictionary(grouping: errors.values, by: \.diagnosticCode)
            .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")
        let status: String
        if storageIssue || configIssue != nil || accessIssue || hostError != nil || !errors.isEmpty || state == "failed" { status = "attention_required" }
        else if activeHost != nil && state == "connected" { status = "connected_service_unverified" }
        else if state == "connecting" || !pending.isEmpty { status = "working" }
        else if !config.trustedConfig { status = "configuration_trust_required" }
        else { status = "idle" }
        var lines = ["pmap \(version) (build \(build))", "Diagnostics format: 2",
                     "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", "Sandbox: \(AppPaths.isSandboxed)",
                     "Status: \(status)", "Host state: \(state)", "Host error: \(hostError?.diagnosticCode ?? "none")",
                     "Configuration error: \(configurationError)", "Configuration trusted: \(config.trustedConfig)",
                     "Hosts: \(hostAliases.count)", "Rules: \(allRules.count)", "Desired: \(desired.count)",
                     "Active: \(active.count)", "Pending: \(pending.count)", "Port errors: \(errors.count)",
                     "Port error categories: \(counts.isEmpty ? "none" : counts)",
                     "Storage error: \(storageIssue)", "Access error: \(accessIssue)",
                     "Restore on launch: \(config.restoreOnLaunch)", "Auto reconnect: \(config.autoReconnect)",
                     "Notifications enabled: \(config.notifications)"]
        func text(_ zh: String, _ en: String) -> String { lang == .zh ? zh : en }
        var actions: [String] = []
        if storageIssue {
            actions.append(text("应用配置读写失败：先备份 pmap 配置，检查文件格式、磁盘空间和目录权限；不要直接删除旧配置。当前修改可能未保存。", "Application configuration could not be read or saved. Back it up, check format, disk space, and directory permissions. Do not delete the old configuration; recent changes may not be saved."))
        }
        if let issue = configIssue {
            actions.append(issue.needsAccess
                ? text("SSH 配置需要授权：点击配置错误旁的授权入口，选择实际文件或链接目标。", "Authorize the actual SSH configuration file or symlink target using Allow Access beside the configuration error.")
                : text("SSH 配置缺失或不可读：用选项菜单的选择配置…选择存在且可读的 SSH 文本配置。", "Use Options → Choose Configuration to select an existing, readable SSH text configuration."))
        } else if accessIssue {
            actions.append(text("存在文件授权问题：重新选择 SSH 配置并检查所引用资源的访问授权。", "Reauthorize the SSH configuration and check access to referenced resources."))
        }
        if !config.trustedConfig {
            actions.append(text("仅在确认配置来源可信后，选择主机并确认信任；信任本身不授予文件权限。", "Only after checking the configuration is trustworthy, select a host and confirm trust. Trust does not grant file access."))
        }
        if let hostError { actions.append(hostError.recoverySteps(lang)) }
        var seen: Set<String> = []
        if let hostError { seen.insert(hostError.diagnosticCode) }
        for error in errors.values.sorted(by: { $0.diagnosticCode < $1.diagnosticCode }) where seen.insert(error.diagnosticCode).inserted {
            actions.append(error.recoverySteps(lang))
        }
        if state == "failed" && hostError == nil {
            actions.append(text("主机故障但缺少错误类别：重新选择主机重试，并检查界面或终端验证的具体错误。", "Host failed without an error category. Reselect it and inspect the UI or Terminal error."))
        }
        if actions.isEmpty {
            actions.append(text("当前未记录故障。若主机未连接，请选择主机；若转发已建立，请用浏览器或客户端确认远端服务。", "No fault is currently recorded. Select a host if disconnected; if forwarding is established, verify the remote service with a browser or client."))
        }
        lines += ["", text("恢复步骤：", "Recovery steps:")]
        lines += actions.enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines += ["", text("恢复验证：主机显示连通，所需端口为绿，最后用客户端确认服务响应；绿灯不保证远端服务健康。", "Verify recovery: host connected, desired ports green, then confirm service response with a client. Green does not guarantee remote service health."),
                  text("说明：Access error 仅反映已记录的文件授权/配置读取问题；false 不保证 SSH 能读取全部资源。通知开关不等于系统已允许通知。本报告不执行任何修复。", "Access error reflects recorded file/configuration access issues; false does not guarantee SSH can read every resource. The notification preference does not confirm OS permission. This report performs no repairs.")]
        return lines.joined(separator: "\n") + "\n"
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
            var recovering = false
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
                    recovering = true
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
                if recovering { self.notify(.reconnected(host: host, ports: self.desired.count)) }
                recovering = false
                for rule in self.allRules where self.desired.contains(rule.local) { self.scheduleOpen(rule) }
                while self.valid(id, host) {
                    do { try await Task.sleep(for: self.heartbeatDelay) } catch { break }
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
                recovering = true
                self.notify(.disconnected)
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
            var delay = self.portRetryDelay
            var recovering = false
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
                if failure == nil {
                    self.active.insert(rule.local)
                    if recovering { self.notify(.portsRestored(1)) }
                    return
                }
                recovering = true
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
