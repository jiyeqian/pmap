import Foundation
import Darwin

// Resolve the real SSH home separately: a sandbox's homeDirectory points at its container.
enum AppPaths {
    static var sshHome: URL {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pmap", isDirectory: true)
    }
    static var config: URL { support.appendingPathComponent("config.json") }
    static var isSandboxed: Bool {
        #if PMAP_SANDBOX
        true
        #else
        false
        #endif
    }
}

enum ConfigurationFile {
    static func load(_ url: URL) throws -> Config {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Config() }
        let config = try JSONDecoder().decode(Config.self, from: data)
        guard config.schemaVersion <= 1 else { throw CocoaError(.coderReadCorrupt) }
        let rules = config.groups.flatMap(\.rules) + (config.adhoc ?? [])
        guard rules.allSatisfy({ isValidPort($0.local) && isValidPort($0.remote) }),
              Set(rules.map(\.local)).count == rules.count else { throw CocoaError(.coderReadCorrupt) }
        return config
    }
    static func save(_ config: Config, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
