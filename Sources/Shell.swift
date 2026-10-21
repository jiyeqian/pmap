import Foundation
import Darwin

struct CommandResult: Sendable {
    var code: Int32
    var output: String
    var error: String
}

/// SSH runs without a terminal; drain both pipes and retain only a bounded diagnostic tail.
final class RunningCommand: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()
    private var stopped = false
    private var launched = false

    init(_ path: String, _ args: [String], directory: URL? = nil) {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment = env
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.append(data, error: false)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.append(data, error: true)
        }
    }

    private func append(_ data: Data, error: Bool) {
        lock.lock(); defer { lock.unlock() }
        if error { errData.append(data); errData = Data(errData.suffix(65_536)) }
        else { outData.append(data); outData = Data(outData.suffix(65_536)) }
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        try process.run()
        launched = true
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return launched && process.isRunning
    }

    func stop() {
        lock.lock()
        stopped = true
        let pid = launched && process.isRunning ? process.processIdentifier : nil
        if pid != nil { process.terminate() }
        lock.unlock()
        if let pid {
            // A resistant child must not hold application termination indefinitely.
            let deadline = Date().addingTimeInterval(0.5)
            while isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    func result(code: Int32? = nil) -> CommandResult {
        // Allow readability callbacks to consume final bytes, without waiting for EOF
        // from an unrelated descendant that inherited a pipe.
        Thread.sleep(forTimeInterval: 0.03)
        lock.lock(); defer { lock.unlock() }
        return CommandResult(code: code ?? (launched && !process.isRunning ? process.terminationStatus : -1),
                             output: String(decoding: outData, as: UTF8.self),
                             error: String(decoding: errData, as: UTF8.self))
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }
}

enum Shell {
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func execute(_ path: String, _ args: [String], timeout: TimeInterval = 5, directory: URL? = nil) async -> CommandResult {
        let command = RunningCommand(path, args, directory: directory)
        return await withTaskCancellationHandler {
            await Task.detached {
                do { try command.start() }
                catch { return CommandResult(code: -1, output: "", error: String(describing: error)) }
                let deadline = Date().addingTimeInterval(timeout)
                while command.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
                if command.isRunning {
                    command.stop()
                    return CommandResult(code: -2, output: "", error: "Command timed out")
                }
                return command.result()
            }.value
        } onCancel: { command.stop() }
    }

    static func run(_ path: String, _ args: [String]) -> String? {
        let command = RunningCommand(path, args)
        do { try command.start() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while command.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if command.isRunning { command.stop(); return nil }
        let result = command.result()
        return result.code == 0 ? result.output : nil
    }

    static func portBusy(_ port: Int) async -> String? {
        let result = await execute("/usr/sbin/lsof", ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "c"])
        guard result.code == 0 else { return nil }
        return result.output.split(separator: "\n").first(where: { $0.hasPrefix("c") }).map { String($0.dropFirst()) }
    }
}
