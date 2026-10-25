import Foundation
import Testing
@testable import PmapCore

@Suite("SSH 文件夹授权流程")
@MainActor
struct SSHFolderTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        return root
    }

    @Test("授权前不读主机，授权后缺 config 仍保持已授权；撤销保留端口")
    func directoryLifecycle() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh")
        let state = home.appendingPathComponent("state.json")
        let store = Store(url: state, sshRoot: ssh)
        store.setLang(.zh, persist: false)
        #expect(store.requiresSSHFolderAuthorization)
        #expect(store.hostAliases.isEmpty)
        #expect(!store.selectSSHDirectory(home))
        #expect(store.selectSSHDirectory(ssh))
        #expect(!store.requiresSSHFolderAuthorization)
        #expect(store.configMessage == "未找到 config 文件，没有可用主机。")
        store.quickInput = "8000#keep"
        store.commitQuick()
        store.confirmConfigurationTrust()
        let restored = Store(url: state, sshRoot: ssh)
        #expect(!restored.requiresSSHFolderAuthorization)
        store.revokeAccess()
        #expect(store.requiresSSHFolderAuthorization)
        #expect(!store.config.trustedConfig)
        #expect(store.adhoc.first?.note == "keep")
        #expect(store.desired.isEmpty)
    }

    @Test("目录失效时断开受管状态并保留待恢复端口")
    func expiredDirectory() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh")
        let store = Store(url: home.appendingPathComponent("state.json"), sshRoot: ssh)
        #expect(store.selectSSHDirectory(ssh))
        store.adhoc = [Rule(local: 8000, remote: 80)]
        store.desired = [8000]
        store.active = [8000]
        store.activeHost = "demo"
        store.hostState["demo"] = .on
        try FileManager.default.removeItem(at: ssh)
        store.refreshOnOpen()
        #expect(store.requiresSSHFolderAuthorization)
        #expect(store.activeHost == nil)
        #expect(store.active.isEmpty)
        #expect(store.desired == [8000])
    }

    @Test("known_hosts 缺失不隐藏主机；可读后消除错误；config 错误文案一致")
    func fileMessages() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh")
        let config = ssh.appendingPathComponent("config")
        try "Host demo\n HostName remote.example\n".write(to: config, atomically: true, encoding: .utf8)
        let store = Store(url: home.appendingPathComponent("state.json"), sshRoot: ssh)
        store.setLang(.zh, persist: false)
        #expect(store.selectSSHDirectory(ssh))
        #expect(store.visibleHosts == ["demo"])
        #expect(store.knownHostsMessage == "未找到 known_hosts 文件，请在终端验证主机。")
        #expect(!store.accessIssue)
        #expect(store.hasErrors)
        try "# fixture".write(to: ssh.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
        store.refreshOnOpen()
        #expect(store.knownHostsIssue == nil)
        try "# empty".write(to: config, atomically: true, encoding: .utf8)
        store.refreshOnOpen()
        #expect(store.configMessage == "config 文件中没有可用主机。")
        try Data([0xff, 0xfe, 0xff]).write(to: config)
        store.refreshOnOpen()
        #expect(store.configMessage == "无法读取 config 文件。")
    }

    @Test("使用实际 UserKnownHostsFile，处理 Include、主机匹配和多个文件")
    func knownHostsSelection() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let text = "Host a,b\n HostName example.org\n UserKnownHostsFile ~/trust/%h %d/extra\nHost b\n UserKnownHostsFile none\n"
        #expect(SSHConfig.knownHostsFiles(in: text, hosts: ["a", "b"], home: home) == [home.appendingPathComponent("trust/example.org"), home.appendingPathComponent("extra")])
        let ssh = home.appendingPathComponent(".ssh")
        try "# trusted".write(to: home.appendingPathComponent("trustfile"), atomically: true, encoding: .utf8)
        try "Host demo\n UserKnownHostsFile \(home.path)/trustfile\n".write(to: ssh.appendingPathComponent("child"), atomically: true, encoding: .utf8)
        try "Include \(ssh.path)/child\n".write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let store = Store(url: home.appendingPathComponent("state.json"), sshRoot: ssh)
        #expect(store.selectSSHDirectory(ssh))
        #expect(store.visibleHosts == ["demo"])
        #expect(store.knownHostsIssue == nil)
    }

    @Test("普通文件读取被拒绝时保留针对性重试，不误触发符号链接自动授权")
    func permissionFailures() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh")
        let config = ssh.appendingPathComponent("config")
        let known = ssh.appendingPathComponent("known_hosts")
        try "Host demo\n".write(to: config, atomically: true, encoding: .utf8)
        try "# known".write(to: known, atomically: true, encoding: .utf8)
        let store = Store(url: home.appendingPathComponent("state.json"), sshRoot: ssh)
        store.setLang(.zh, persist: false)
        #expect(store.selectSSHDirectory(ssh))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: known.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
        store.refreshOnOpen()
        #expect(store.configMessage == "无法读取 config 文件。")
        #expect(store.requiredFileAccess?.target == SSHConfig.realTarget(config))
        #expect(store.supplementalAccess == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: known.path)
        store.refreshOnOpen()
        #expect(store.visibleHosts == ["demo"])
        #expect(store.knownHostsMessage == "无法读取 known_hosts 文件。")
        #expect(store.requiredFileAccess?.target == SSHConfig.realTarget(known))
        #expect(store.supplementalAccess == nil)
    }

    @Test("可读的外部符号链接不请求授权，断链报告缺失而非权限不足")
    func symlinkPreflight() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh")
        let target = home.appendingPathComponent("real-config")
        try "Host demo\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: ssh.appendingPathComponent("config"), withDestinationURL: target)
        let store = Store(url: home.appendingPathComponent("state.json"), sshRoot: ssh)
        #expect(store.selectSSHDirectory(ssh))
        #expect(store.configIssue == nil)
        #expect(store.supplementalAccess == nil)
        try FileManager.default.removeItem(at: target)
        store.refreshOnOpen()
        #expect(store.configIssue == .missing(SSHConfig.realTarget(target)))
        #expect(store.supplementalAccess == nil)
    }
}
