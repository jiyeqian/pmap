import Testing
import Foundation
@testable import PmapCore

@Suite("极简配置流程")
@MainActor
struct ConfigurationFlowTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("包含命令的配置在确认前仅列出主机")
    func chooseFile() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("SSH custom.conf")
        try "Host demo\n HostName remote.example\n ProxyCommand ssh jump -W %h:%p\n".write(to: file, atomically: true, encoding: .utf8)
        let backend = FakeTunnel()
        let state = directory.appendingPathComponent("state.json")
        let store = Store(url: state, scanHosts: false, factory: { _, _ in backend })
        store.selectConfiguration(file)
        #expect(store.sshConfigPath == file.path)
        #expect(store.visibleHosts == ["demo"])
        #expect(!store.canConnect)
        store.selectHost("demo")
        #expect(await backend.connectionStarted == false)
        store.confirmConfigurationTrust()
        #expect(store.canConnect)
        let restored = Store(url: state, scanHosts: false)
        #expect(restored.sshConfigPath == file.path)
        #expect(restored.config.trustedConfig)
        await store.shutdownAll()
    }

    @Test("普通配置免确认，命令与 Include 变化撤销既有信任")
    func contentTrust() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        let included = directory.appendingPathComponent("extra")
        let state = directory.appendingPathComponent("state.json")
        try "Host demo\n HostName remote.example\n".write(to: file, atomically: true, encoding: .utf8)
        let store = Store(url: state, scanHosts: false)
        store.selectConfiguration(file)
        #expect(store.canConnect)
        try "Host demo\n ProxyCommand ssh jump -W %h:%p\n".write(to: included, atomically: true, encoding: .utf8)
        try "Include \(included.path)\n".write(to: file, atomically: true, encoding: .utf8)
        store.refreshHosts()
        #expect(!store.canConnect)
        store.confirmConfigurationTrust()
        #expect(store.canConnect)
        let restored = Store(url: state, scanHosts: false)
        restored.refreshHosts()
        #expect(restored.canConnect)
        restored.adhoc = [Rule(local: 3080, remote: 80)]
        restored.desired = [3080]
        restored.activeHost = "demo"
        try "Host demo\n ProxyCommand ssh different -W %h:%p\n".write(to: included, atomically: true, encoding: .utf8)
        restored.refreshHosts()
        #expect(!restored.canConnect)
        #expect(restored.activeHost == nil)
        #expect(restored.desired == [3080])
        restored.revokeAccess()
        #expect(restored.config.trustedConfigDigest == nil)
        #expect(!SSHConfig.requiresCommandTrust("# ProxyCommand bad\nHost demo\n ProxyCommand none\n LocalCommand disabled"))
        for text in ["ProxyCommand=ssh jump", "KnownHostsCommand /tmp/check", "Match exec \"test -f x\"", "Match !exec \"test -f x\""] {
            #expect(SSHConfig.requiresCommandTrust(text))
        }
    }

    @Test("打开面板时自动读取配置变化")
    func refreshOnOpen() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try "Host first\n".write(to: file, atomically: true, encoding: .utf8)
        var config = Config()
        config.sshConfigFile = file.path
        let state = directory.appendingPathComponent("state.json")
        try ConfigurationFile.save(config, to: state)
        let store = Store(url: state, sshRoot: directory)
        #expect(store.selectSSHDirectory(directory))
        #expect(store.visibleHosts == ["first"])
        try "Host second\n".write(to: file, atomically: true, encoding: .utf8)
        store.refreshOnOpen()
        #expect(store.visibleHosts == ["second"])
    }

    @Test("外部符号链接错误指出真正需要授权的目标")
    func symlinkTarget() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("outside.conf")
        let link = directory.appendingPathComponent("config")
        try "Host linked\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let issue = ConfigReadIssue.classify(CocoaError(.fileReadNoPermission), at: link)
        #expect(issue == .access(target.resolvingSymlinksInPath()))
        #expect(try SSHConfig.readHosts(at: link) == ["linked"])
    }

    @Test("切换配置清除旧信任，缺失文件保留可操作错误")
    func switchingConfiguration() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("missing.conf")
        let store = Store(url: directory.appendingPathComponent("state.json"), scanHosts: false)
        store.confirmConfigurationTrust()
        store.selectConfiguration(file)
        #expect(!store.config.trustedConfig)
        #expect(store.visibleHosts.isEmpty)
        #expect(store.configIssue == .missing(file.resolvingSymlinksInPath()))
        #expect(store.hasErrors)
        await store.shutdownAll()
    }

    @Test("重置立即清除信任，迟到清理不覆盖新选择")
    func resetDoesNotEraseNewSelection() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.conf")
        let second = directory.appendingPathComponent("second.conf")
        try "Host first\n".write(to: first, atomically: true, encoding: .utf8)
        try "Host second\n".write(to: second, atomically: true, encoding: .utf8)
        let store = Store(url: directory.appendingPathComponent("state.json"), scanHosts: false)
        store.selectConfiguration(first)
        store.confirmConfigurationTrust()
        store.revokeAccess()
        #expect(!store.config.trustedConfig)
        #expect(store.visibleHosts.isEmpty)
        store.selectConfiguration(second)
        store.confirmConfigurationTrust()
        for _ in 0..<10 { await Task.yield() }
        #expect(store.sshConfigPath == second.path)
        #expect(store.visibleHosts == ["second"])
        #expect(store.canConnect)
        await store.shutdownAll()
    }

    @Test("旧目录配置仍然兼容")
    func legacyDirectory() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        var config = Config()
        config.sshDirectory = directory.path
        try ConfigurationFile.save(config, to: state)
        let store = Store(url: state, scanHosts: false)
        #expect(store.sshConfigPath == directory.appendingPathComponent("config").path)
    }
}

@Suite("文件授权错误")
struct FileAccessErrorTests {
    @Test("身份文件权限错误不再误报普通认证失败")
    func identityAccess() {
        let path = "/tmp/İ 密钥"
        let error = PortError.classify("Warning: Identity file \(path) not accessible: Permission denied.\nPermission denied (publickey).", localPort: 0)
        #expect(error == .fileAccess(path: path))
        #expect(PortError.classify(#"Load key "/tmp/key": Permission denied"#, localPort: 0) == .fileAccess(path: "/tmp/key"))
        #expect(PortError.classify("Permission denied (publickey).", localPort: 0) == .authFailed)
    }
}
