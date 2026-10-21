import Foundation
import CryptoKit

protocol TunnelBackend: Sendable {
    func connect() async -> PortError?
    func check() async -> Bool
    func forward(_ rule: Rule) async -> PortError?
    func cancel(_ rule: Rule) async -> PortError?
    func shutdown() async
}

/// One owner and one private socket per connection attempt. Old cleanup can never
/// terminate a newer connection to the same alias.
actor SSHSession: TunnelBackend {
    let host: String
    let configPath: String
    let socket: String
    private let directory: URL
    private var master: RunningCommand?
    private var closed = false

    init(host: String, configPath: String, directory: URL = FileManager.default.temporaryDirectory) {
        self.host = host
        self.configPath = configPath
        let name = SHA256.hash(data: Data(UUID().uuidString.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        self.directory = directory.appendingPathComponent("pm-\(name)", isDirectory: true)
        // Use a relative socket in a private working directory: Unix socket limits
        // include OpenSSH's temporary suffix and long sandbox container paths.
        self.socket = "c"
    }

    static func options(configPath: String, socket: String) -> [String] {
        ["-F", configPath, "-S", socket,
         "-o", "ControlMaster=no", "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no",
         "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
         "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
         "-o", "PermitLocalCommand=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
         "-o", "ClearAllForwardings=yes", "-o", "ExitOnForwardFailure=yes"]
    }

    private var options: [String] { Self.options(configPath: configPath, socket: socket) }
    private var controlOptions: [String] { ["-F", "/dev/null", "-S", socket, "-o", "BatchMode=yes"] }

    func connect() async -> PortError? {
        guard !closed, SSHConfig.isSafeAlias(host) else { return .hostNotFound }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return .ssh(raw: String(describing: error)) }
        let command = RunningCommand("/usr/bin/ssh", options + ["-M", "-N", "-T", "--", host], directory: directory)
        master = command
        do { try command.start() } catch { return .ssh(raw: String(describing: error)) }
        let deadline = Date().addingTimeInterval(12)
        while !Task.isCancelled && !closed && command.isRunning && Date() < deadline {
            if await check() { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let failure = command.result().error
        command.stop()
        master = nil
        return failure.isEmpty ? .sshConnectTimeout : PortError.classify(failure, localPort: 0)
    }

    func check() async -> Bool {
        guard !closed, master?.isRunning == true else { return false }
        return await Shell.execute("/usr/bin/ssh", controlOptions + ["-O", "check", "--", host], timeout: 2, directory: directory).code == 0
    }

    func forward(_ rule: Rule) async -> PortError? {
        guard !closed else { return .noControlConnection }
        let result = await Shell.execute("/usr/bin/ssh", controlOptions + ["-O", "forward", "-L", "127.0.0.1:\(rule.local):127.0.0.1:\(rule.remote)", "--", host], directory: directory)
        return result.code == 0 ? nil : PortError.classify(result.error, localPort: rule.local)
    }

    func cancel(_ rule: Rule) async -> PortError? {
        guard !closed else { return nil }
        let result = await Shell.execute("/usr/bin/ssh", controlOptions + ["-O", "cancel", "-L", "127.0.0.1:\(rule.local):127.0.0.1:\(rule.remote)", "--", host], directory: directory)
        return result.code == 0 ? nil : PortError.classify(result.error, localPort: rule.local)
    }

    func shutdown() async {
        closed = true
        let command = master
        master = nil
        // Terminating the owned foreground master closes every listener. No forked
        // ControlPersist daemon survives the app's normal shutdown.
        await Task.detached { command?.stop() }.value
        try? FileManager.default.removeItem(at: directory)
    }
}
