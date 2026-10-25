import Testing
import Foundation
@testable import PmapCore

@Suite("0.1.5 功能恢复")
@MainActor
struct RestoreCompatibilityTests {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for restored behavior")
    }

    @Test("非法输入、重复输入和备注持久化")
    func inputAndNotes() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let url = path.appendingPathComponent("state.json")
        let store = Store(url: url, scanHosts: false)
        for value in ["235dagg", "0", "65536", "8000::80"] {
            store.quickInput = value
            store.commitQuick()
            #expect(store.inputInvalid == .badFormat)
            #expect(store.quickInput == value)
            #expect(store.adhoc.isEmpty)
            #expect(!store.inputInvalid!.description(.zh).isEmpty)
        }
        store.quickInput = "3080#deepseek"
        store.commitQuick()
        #expect(store.inputInvalid == nil)
        #expect(store.adhoc.first?.displayNote == "deepseek")
        #expect(store.adhoc.first?.accessibleLabel == "3080:3080 · deepseek")
        store.quickInput = "3080:80#duplicate"
        store.commitQuick()
        #expect(store.inputInvalid == .duplicatedPort)
        #expect(store.duplicatePort == 3080)
        #expect(store.adhoc.count == 1)
        let restored = Store(url: url, scanHosts: false)
        #expect(restored.adhoc.first?.note == "deepseek")
    }

    @Test("描述编辑保存且不改变端口与连接状态")
    func editNotes() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let url = path.appendingPathComponent("state.json")
        let store = Store(url: url, scanHosts: false)
        let rule = Rule(local: 3080, remote: 80, note: "old")
        store.adhoc = [rule]
        store.config.groups = [Group(name: "group", rules: [Rule(local: 9000, remote: 90)])]
        store.desired = [3080]
        store.active = [3080]
        store.updateNote(rule, note: " new ")
        store.updateNote(store.config.groups[0].rules[0], note: "group note")
        #expect(store.active == [3080])
        #expect(store.desired == [3080])
        let saved = try ConfigurationFile.load(url)
        #expect(saved.adhoc?.first == Rule(local: 3080, remote: 80, note: "new"))
        #expect(saved.groups[0].rules[0].note == "group note")
        store.updateNote(rule, note: "  ")
        #expect(store.adhoc[0].note == nil)
    }

    @Test("过滤含点、本机、多别名及 Include 中的本机定义")
    func hostFiltering() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let child = path.appendingPathComponent("extra")
        try "Host local second\n HostName ::1\nHost remote\n HostName example.org\n".write(to: child, atomically: true, encoding: .utf8)
        let main = path.appendingPathComponent("config")
        try "Host github.com *.test !excluded\nInclude \(child.path)\nHost loop\n HostName LOCALHOST\nHost good\n HostName other.example\n".write(to: main, atomically: true, encoding: .utf8)
        #expect(try SSHConfig.readHosts(at: main) == ["remote", "good"])
        #expect(SSHConfig.parseHosts("Host a\n HostName remote.example\nHost *\n HostName localhost\n") == ["a"])
        #expect(SSHConfig.parseHosts("Host a\nHost * !a\n HostName localhost\n") == ["a"])
    }

    @Test("旧数据导入保留备注与开启状态，不继承信任或覆盖授权")
    func importAndResume() async throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let source = path.appendingPathComponent("old.json")
        let original = Data(#"{"host":"saved","adhoc":[{"local":3080,"remote":3080,"note":"deepseek"}],"active":[3080],"lang":"en","trustedConfig":true,"sshConfigFile":"/untrusted/config"}"#.utf8)
        try original.write(to: source)
        let backend = FakeTunnel()
        let store = Store(url: path.appendingPathComponent("new.json"), scanHosts: false, factory: { _, _ in backend })
        let ssh = path.appendingPathComponent("ssh.conf")
        try "Host saved\n HostName remote.example\n ProxyCommand ssh jump -W %h:%p\n".write(to: ssh, atomically: true, encoding: .utf8)
        store.selectConfiguration(ssh)
        try store.importLegacyConfiguration(source)
        #expect(!store.config.trustedConfig)
        #expect(store.sshConfigPath == ssh.path)
        #expect(store.desired == [3080])
        #expect(store.lang == .en)
        #expect(store.adhoc.first?.note == "deepseek")
        #expect(store.hasSavedSession)
        #expect(store.shouldRestoreSelection("saved"))
        #expect(!store.shouldRestoreSelection("other"))
        store.autoConnectIfNeeded()
        #expect(await backend.connectionCalls == 0)
        // Re-selecting an authorized SSH file must not erase an imported/upgraded session.
        store.selectConfiguration(ssh)
        #expect(store.desired == [3080])
        store.confirmConfigurationTrust()
        store.selectHost("saved", restore: store.shouldRestoreSelection("saved"))
        try await wait { store.active == [3080] }
        #expect(try Data(contentsOf: source) == original)
        await store.shutdownAll()
    }

    @Test("普通版旧配置直接读取，信任后恢复，关闭启动恢复时不自动连接")
    func directUpgrade() async throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let state = path.appendingPathComponent("state.json")
        try Data(#"{"host":"saved","adhoc":[{"local":3080,"remote":80,"note":"deepseek"}],"active":[3080],"lang":"zh"}"#.utf8).write(to: state)
        let backend = FakeTunnel()
        let store = Store(url: state, scanHosts: false, factory: { _, _ in backend })
        #expect(store.configurationURL == AppPaths.sshHome.appendingPathComponent(".ssh/config"))
        store.hostAliases = ["saved"]
        store.autoConnectIfNeeded()
        #expect(await backend.connectionCalls == 0)
        #expect(store.desired == [3080])
        #expect(store.hasSavedSession)
        store.confirmConfigurationTrust()
        store.config.restoreOnLaunch = false
        store.autoConnectIfNeeded()
        #expect(await backend.connectionCalls == 0)
        store.config.restoreOnLaunch = true
        store.autoConnectIfNeeded()
        try await wait { store.active == [3080] }
        #expect(store.adhoc.first?.note == "deepseek")
        await store.shutdownAll()
    }

    @Test("导入缺失或损坏文件不改变当前状态及原文件")
    func invalidImport() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let target = path.appendingPathComponent("state.json")
        let store = Store(url: target, scanHosts: false)
        store.quickInput = "9000#keep"
        store.commitQuick()
        let before = try Data(contentsOf: target)
        let bad = path.appendingPathComponent("bad.json")
        try Data("invalid".utf8).write(to: bad)
        #expect(throws: (any Error).self) { try store.importLegacyConfiguration(bad) }
        #expect(throws: (any Error).self) { try store.importLegacyConfiguration(path.appendingPathComponent("missing.json")) }
        #expect(store.adhoc.first?.note == "keep")
        #expect(try Data(contentsOf: target) == before)
    }

    @Test("升级后恢复、重连和通知统一启用")
    func automaticBehaviorOnUpgrade() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let url = path.appendingPathComponent("state.json")
        var previous = Config()
        previous.restoreOnLaunch = false
        previous.autoReconnect = false
        previous.notifications = false
        try ConfigurationFile.save(previous, to: url)
        let store = Store(url: url, scanHosts: false)
        #expect(store.config.restoreOnLaunch)
        #expect(store.config.autoReconnect)
        #expect(store.config.notifications)
    }

    @Test("通知默认启用，断开、重连与端口恢复分别发送")
    func notifications() async throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(at: path) }
        var notices: [ConnectionNotice] = []
        var requests = 0
        let backend = FakeTunnel(connectFailure: .timedOut)
        let store = Store(url: path.appendingPathComponent("state.json"), scanHosts: false,
                          retryDelay: .milliseconds(20), heartbeatDelay: .milliseconds(20), portRetryDelay: .milliseconds(20),
                          sendNotice: { notice, _ in notices.append(notice) }, requestNotifications: { requests += 1 },
                          factory: { _, _ in backend })
        store.config.trustedConfig = true
        store.hostAliases = ["saved"]
        store.adhoc = [Rule(local: 3080, remote: 80)]
        #expect(store.config.notifications)
        #expect(requests == 0)
        store.setNotifications(true)
        #expect(requests == 1)
        store.selectHost("saved")
        try await wait { store.hostState["saved"] == .failed }
        await backend.setConnectFailure(nil)
        try await wait { notices.contains(.reconnected(host: "saved", ports: 0)) }
        await backend.setForwardFailure(.localPortBusy(port: 3080, by: nil))
        store.open(store.allRules[0])
        try await wait { store.errors[3080] != nil }
        await backend.setForwardFailure(nil)
        try await wait { notices.contains(.portsRestored(1)) }
        await backend.setHealthy(false)
        try await wait { notices.contains(.disconnected) }
        store.setNotifications(false)
        let count = notices.count
        await backend.setHealthy(true)
        try await wait { store.hostState["saved"] == .on }
        #expect(notices.count == count)
        #expect(requests == 1)
        await store.shutdownAll()
    }
}
