#if PMAP_TEST_HARNESS
import Foundation

enum IntegrationProbe {
    static func run() async -> Int32 {
        guard let resources = Bundle.main.resourceURL else { return 1 }
        let fixture = resources.appendingPathComponent("TestFixture")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("probe-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: work) }
            for name in ["client_key", "known_hosts"] {
                try FileManager.default.copyItem(at: fixture.appendingPathComponent(name), to: work.appendingPathComponent(name))
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: work.appendingPathComponent("client_key").path)
            let user = NSUserName()
            let config = "Host fixture\n HostName 127.0.0.1\n Port 39227\n User \(user)\n IdentityFile \(work.path)/client_key\n IdentitiesOnly yes\n UserKnownHostsFile \(work.path)/known_hosts\n"
            let configURL = work.appendingPathComponent("config")
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            let longDirectory = work.appendingPathComponent(String(repeating: "long", count: 32))
            try FileManager.default.createDirectory(at: longDirectory, withIntermediateDirectories: true)
            let session = SSHSession(host: "fixture", configPath: configURL.path, directory: longDirectory)
            if let error = await session.connect() { print("FAIL connect: \(error)"); await session.shutdown(); return 1 }
            print("PASS system SSH connected (sandbox=\(AppPaths.isSandboxed))")
            let occupied = await session.forward(Rule(local: 39228, remote: 39228))
            guard case .localPortBusy(port: 39228, by: _) = occupied else {
                print("FAIL occupied port: \(String(describing: occupied))"); await session.shutdown(); return 1
            }
            print("PASS occupied port classified with optional process detail")
            let rule = Rule(local: 39229, remote: 39228)
            if let error = await session.forward(rule) { print("FAIL forward: \(error)"); await session.shutdown(); return 1 }
            let response = await Shell.execute("/usr/bin/curl", ["--silent", "--show-error", "--max-time", "3", "http://127.0.0.1:39229/"])
            guard response.code == 0, response.output == "pmap-tunnel-ok" else {
                print("FAIL payload: \(response.code) \(response.error)"); await session.shutdown(); return 1
            }
            print("PASS payload through real SSH tunnel")
            if let error = await session.cancel(rule) { print("FAIL cancel: \(error)"); await session.shutdown(); return 1 }
            let stopped = await Shell.execute("/usr/bin/curl", ["--silent", "--max-time", "1", "http://127.0.0.1:39229/"])
            guard stopped.code != 0 else { print("FAIL listener still open"); await session.shutdown(); return 1 }
            print("PASS cancel releases listener")
            _ = await session.forward(rule)
            await session.shutdown()
            let exited = await Shell.execute("/usr/bin/curl", ["--silent", "--max-time", "1", "http://127.0.0.1:39229/"])
            guard exited.code != 0 else { print("FAIL shutdown listener still open"); return 1 }
            print("PASS shutdown releases listener")
            let unknownConfig = config + "\nHost *\n UserKnownHostsFile /dev/null\n"
            // Override the known-hosts file on the specific host, before its original value.
            let untrusted = unknownConfig.replacingOccurrences(of: "UserKnownHostsFile \(work.path)/known_hosts", with: "UserKnownHostsFile /dev/null")
            try untrusted.write(to: configURL, atomically: true, encoding: .utf8)
            let unknown = SSHSession(host: "fixture", configPath: configURL.path)
            let failure = await unknown.connect()
            await unknown.shutdown()
            guard failure == .hostKeyRejected else { print("FAIL unknown host accepted: \(String(describing: failure))"); return 1 }
            print("PASS unknown host is rejected")
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            return await managedLifecycle(configURL: configURL, work: work)
        } catch { print("FAIL fixture: \(error)"); return 1 }
    }

    @MainActor
    private static func managedLifecycle(configURL: URL, work: URL) async -> Int32 {
        let registry = ProbeSessions()
        let state = work.appendingPathComponent("state.json")
        let rule = Rule(local: 39229, remote: 39228, note: "fixture")
        let store = Store(url: state, scanHosts: false, retryDelay: .milliseconds(200), heartbeatDelay: .milliseconds(200),
                          sendNotice: { _, _ in }, factory: { registry.make($0, $1) })
        store.selectConfiguration(configURL)
        // Production filters loopback aliases; this isolated fixture must exercise the manager locally.
        store.hostAliases = ["fixture"]
        store.adhoc = [rule]
        store.selectHost("fixture")
        store.open(rule)
        guard await wait({ store.active.contains(rule.local) }), await payload() else {
            print("FAIL managed open/payload"); await store.shutdownAll(); return 1
        }
        print("PASS managed host selection and forwarding payload")
        await registry.first?.shutdown()
        guard await wait({ registry.count >= 2 && store.active.contains(rule.local) }), await payload() else {
            print("FAIL reconnect after session loss"); await store.shutdownAll(); return 1
        }
        print("PASS real session loss reconnects and restores payload")
        store.close(rule)
        guard await wait({ !store.active.contains(rule.local) && !store.desired.contains(rule.local) }), !(await payload()) else {
            print("FAIL managed stop"); await store.shutdownAll(); return 1
        }
        store.open(rule)
        guard await wait({ store.active.contains(rule.local) }) else {
            print("FAIL managed reopen"); await store.shutdownAll(); return 1
        }
        await store.shutdownAll()
        guard !(await payload()) else { print("FAIL managed quit listener"); return 1 }
        print("PASS managed stop and shutdown release listener")

        let restored = Store(url: state, scanHosts: false, sendNotice: { _, _ in })
        restored.hostAliases = ["fixture"]
        restored.autoConnectIfNeeded()
        guard await wait({ restored.active.contains(rule.local) }), await payload() else {
            print("FAIL saved session restore"); await restored.shutdownAll(); return 1
        }
        print("PASS fresh store restores saved host, port and payload")
        restored.removeRuleAnywhere(rule)
        guard await wait({ restored.allRules.isEmpty && restored.active.isEmpty }), !(await payload()) else {
            print("FAIL managed delete"); await restored.shutdownAll(); return 1
        }
        restored.adhoc = [rule]
        restored.open(rule)
        guard await wait({ restored.active.contains(rule.local) }) else {
            print("FAIL reopen before revoke"); await restored.shutdownAll(); return 1
        }
        let original = try? Data(contentsOf: configURL)
        restored.revokeAccess()
        guard await wait({ !Shell.localPortInUse(rule.local) }), restored.activeHost == nil,
              restored.desired.isEmpty, restored.adhoc.first == rule,
              original == (try? Data(contentsOf: configURL)) else {
            print("FAIL revoke lifecycle"); await restored.shutdownAll(); return 1
        }
        await restored.shutdownAll()
        print("PASS delete and revoke release listener, preserve rules and source configuration")
        return 0
    }

    @MainActor
    private static func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func payload() async -> Bool {
        let result = await Shell.execute("/usr/bin/curl", ["--silent", "--max-time", "1", "http://127.0.0.1:39229/"])
        return result.code == 0 && result.output == "pmap-tunnel-ok"
    }
}

private final class ProbeSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [SSHSession] = []
    var count: Int { lock.withLock { sessions.count } }
    var first: SSHSession? { lock.withLock { sessions.first } }
    func make(_ host: String, _ path: String) -> SSHSession {
        let session = SSHSession(host: host, configPath: path)
        lock.withLock { sessions.append(session) }
        return session
    }

}
#endif
