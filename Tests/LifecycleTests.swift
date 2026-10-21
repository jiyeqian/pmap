import Testing
import Foundation
@testable import PmapCore

actor FakeTunnel: TunnelBackend {
    var connectGate: CheckedContinuation<PortError?, Never>?
    var forwardGate: CheckedContinuation<PortError?, Never>?
    var connectionStarted = false
    var connectionCalls = 0
    var connectFailure: PortError?
    var forwardingStarted = false
    var waitConnect = false
    var waitForward = false
    var forwardFailure: PortError?
    var cancelFailure: PortError?
    var forwards = 0
    var cancellations = 0
    var shutdowns = 0
    init(waitConnect: Bool = false, waitForward: Bool = false, connectFailure: PortError? = nil, forwardFailure: PortError? = nil, cancelFailure: PortError? = nil) {
        self.waitConnect = waitConnect; self.waitForward = waitForward
        self.connectFailure = connectFailure
        self.forwardFailure = forwardFailure; self.cancelFailure = cancelFailure
    }
    func connect() async -> PortError? {
        connectionStarted = true
        connectionCalls += 1
        if waitConnect { return await withCheckedContinuation { connectGate = $0 } }
        return connectFailure
    }
    func releaseConnect() { connectGate?.resume(returning: nil); connectGate = nil }
    func forward(_ rule: Rule) async -> PortError? {
        forwards += 1; forwardingStarted = true
        if waitForward { return await withCheckedContinuation { forwardGate = $0 } }
        return forwardFailure
    }
    func releaseForward() { forwardGate?.resume(returning: nil); forwardGate = nil }
    func check() async -> Bool { true }
    func cancel(_ rule: Rule) async -> PortError? { cancellations += 1; return cancelFailure }
    func shutdown() async { shutdowns += 1 }
}

@Suite("连接生命周期")
@MainActor
struct LifecycleTests {
    private func makeStore(_ first: FakeTunnel, second: FakeTunnel? = nil, retryDelay: Duration = .seconds(3)) -> Store {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        let store = Store(url: url, scanHosts: false, retryDelay: retryDelay, factory: { host, _ in host == "b" ? (second ?? first) : first })
        store.config.trustedConfig = true
        store.config.autoReconnect = false
        store.hostAliases = ["a", "b"]
        store.adhoc = [Rule(local: 28080, remote: 80)]
        return store
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for lifecycle transition")
    }
    @Test("退避期间关闭自动重连不会再发起连接")
    func stopReconnectDuringBackoff() async throws {
        let backend = FakeTunnel(connectFailure: .timedOut)
        let store = makeStore(backend, retryDelay: .milliseconds(30))
        store.config.autoReconnect = true
        store.selectHost("a")
        try await wait { store.hostState["a"] == .failed }
        store.config.autoReconnect = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(await backend.connectionCalls == 1)
        await store.shutdownAll()
    }
    @Test("未授权的配置不能启动系统 SSH")
    func requiresTrust() async {
        let backend = FakeTunnel()
        let store = makeStore(backend)
        store.config.trustedConfig = false
        store.selectHost("a")
        #expect(store.activeHost == nil)
        #expect(await backend.connectionStarted == false)
        await store.shutdownAll()
    }
    @Test("损坏配置不会被保存默认值覆盖")
    func preservesCorruptConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let original = Data("broken configuration".utf8)
        try original.write(to: url)
        let store = Store(url: url, scanHosts: false)
        store.save()
        #expect(store.storageIssue)
        #expect(try Data(contentsOf: url) == original)
    }
    @Test("切换主机后旧连接完成不能覆盖新连接")
    func staleConnection() async throws {
        let old = FakeTunnel(waitConnect: true)
        let new = FakeTunnel()
        let store = makeStore(old, second: new)
        store.selectHost("a")
        try await wait { await old.connectionStarted }
        store.selectHost("b")
        try await wait { store.hostState["b"] == .on }
        await old.releaseConnect()
        try await wait { await old.shutdowns > 0 }
        #expect(store.activeHost == "b")
        #expect(store.hostState["a"] == .off)
        await store.shutdownAll()
    }
    @Test("失败端口可停止期望开启，不会再次开启")
    func stopFailedForward() async throws {
        let backend = FakeTunnel(forwardFailure: .localPortBusy(port: 28080, by: nil))
        let store = makeStore(backend)
        store.selectHost("a")
        try await wait { store.hostState["a"] == .on }
        let rule = store.allRules[0]
        store.toggle(rule)
        try await wait { store.errors[rule.local] != nil && !store.pending.contains(rule.local) }
        store.toggle(rule)
        try await wait { !store.desired.contains(rule.local) && !store.pending.contains(rule.local) }
        #expect(await backend.forwards == 1)
        await store.shutdownAll()
    }
    @Test("删除正在建立的转发会清理迟到的成功结果")
    func deleteInFlight() async throws {
        let backend = FakeTunnel(waitForward: true)
        let store = makeStore(backend)
        store.selectHost("a")
        try await wait { store.hostState["a"] == .on }
        let rule = store.allRules[0]
        store.open(rule)
        try await wait { await backend.forwardingStarted }
        store.removeRuleAnywhere(rule)
        await backend.releaseForward()
        try await wait { store.allRules.isEmpty }
        #expect(await backend.cancellations == 1)
        #expect(store.active.isEmpty)
        #expect(store.desired.isEmpty)
        await store.shutdownAll()
    }
    @Test("取消转发失败时保留实际开启状态与规则")
    func cancelFailure() async throws {
        let backend = FakeTunnel(cancelFailure: .noControlConnection)
        let store = makeStore(backend)
        store.selectHost("a")
        try await wait { store.hostState["a"] == .on }
        let rule = store.allRules[0]
        store.open(rule)
        try await wait { store.active.contains(rule.local) }
        store.removeRuleAnywhere(rule)
        try await wait { store.errors[rule.local] != nil }
        #expect(store.active.contains(rule.local))
        #expect(store.allRules.contains(rule))
        await store.shutdownAll()
    }
    @Test("退出期间迟到的连接结果会被清理")
    func quitInFlight() async throws {
        let backend = FakeTunnel(waitConnect: true)
        let store = makeStore(backend)
        store.selectHost("a")
        try await wait { await backend.connectionStarted }
        await store.shutdownAll()
        await backend.releaseConnect()
        try await wait { await backend.shutdowns >= 2 }
        #expect(store.activeHost == nil)
        #expect(store.active.isEmpty)
    }
}

@Suite("进程执行")
struct CommandTests {
    @Test("终端命令保留引号与空格，不解释配置路径")
    func quotedPath() async {
        let value = "config with ' quote; literal"
        let result = await Shell.execute("/bin/sh", ["-c", "printf '%s' " + Shell.quoted(value)])
        #expect(result.code == 0)
        #expect(result.output == value)
    }
    @Test("同时消费 stdout stderr 且限制缓存大小")
    func drainBothPipes() async {
        let result = await Shell.execute("/bin/sh", ["-c", "i=0; while [ $i -lt 5000 ]; do printf 'abcdefghijklmnopqrstuvwxyz0123456789\\n'; printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\\n' >&2; i=$((i+1)); done"], timeout: 10)
        #expect(result.code == 0)
        #expect(!result.output.isEmpty && !result.error.isEmpty)
        #expect(result.output.utf8.count <= 65_536)
        #expect(result.error.utf8.count <= 65_536)
    }
    @Test("超时终止子进程")
    func deadline() async {
        let start = Date()
        let result = await Shell.execute("/bin/sleep", ["30"], timeout: 0.1)
        #expect(result.code == -2)
        #expect(Date().timeIntervalSince(start) < 2)
    }
    @Test("取消任务会终止子进程")
    func cancellation() async throws {
        let task = Task { await Shell.execute("/bin/sleep", ["30"], timeout: 30) }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        task.cancel()
        let result = await task.value
        #expect(result.code != 0)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

@Suite("持久化与配置兼容")
struct ConfigurationTests {
    @Test("旧版配置有默认值并可原子往返")
    func legacy() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"host":"a","adhoc":[{"local":8000,"remote":80}],"active":[8000]}"#.utf8))
        #expect(config.restoreOnLaunch)
        #expect(!config.trustedConfig)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try ConfigurationFile.save(config, to: url)
        #expect(try ConfigurationFile.load(url).host == "a")
    }
    @Test("拒绝重复或越界端口以及未来配置版本")
    func rejectInvalid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        var config = Config()
        config.adhoc = [Rule(local: 0, remote: 80)]
        try ConfigurationFile.save(config, to: url)
        #expect(throws: (any Error).self) { try ConfigurationFile.load(url) }
        config.adhoc = [Rule(local: 80, remote: 80), Rule(local: 80, remote: 81)]
        try ConfigurationFile.save(config, to: url)
        #expect(throws: (any Error).self) { try ConfigurationFile.load(url) }
        config.adhoc = []; config.schemaVersion = 2
        try ConfigurationFile.save(config, to: url)
        #expect(throws: (any Error).self) { try ConfigurationFile.load(url) }
    }
    @Test("端口对拒绝空字段与重复冒号")
    func emptyPortFields() {
        #expect(parseQuickInput(":8000:80") == nil)
        #expect(parseQuickInput("8000::80") == nil)
        #expect(parseQuickInput("8000:80:") == nil)
    }
    @Test("Include 递归、引号、注释和循环均有界")
    func includes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config")
        let child = dir.appendingPathComponent("extra config")
        try "Host=\"a.example\" # ignored\nInclude \"\(child.path)\"\n".write(to: file, atomically: true, encoding: .utf8)
        try "Host b\nInclude \(file.path)\n".write(to: child, atomically: true, encoding: .utf8)
        #expect(try SSHConfig.readHosts(at: file) == ["a.example", "b"])
        #expect(!SSHConfig.isSafeAlias("-oProxyCommand=bad"))
        #expect(!SSHConfig.isSafeAlias("../../socket"))
    }
    @Test("SSH 参数禁止自动信任、后台逃逸与隐含端口转发")
    func sshOptions() {
        let options = SSHSession.options(configPath: "/test/config", socket: "/test/socket")
        #expect(options.contains("StrictHostKeyChecking=yes"))
        #expect(options.contains("BatchMode=yes"))
        #expect(options.contains("ControlPersist=no"))
        #expect(options.contains("ForkAfterAuthentication=no"))
        #expect(options.contains("ClearAllForwardings=yes"))
        #expect(options.contains("PermitLocalCommand=no"))
    }
}
