import Foundation
import CryptoKit
import Darwin

enum ConfigReadIssue: Error, Equatable {
    case access(URL), missing(URL), invalid(URL)
    var target: URL {
        switch self { case .access(let url), .missing(let url), .invalid(let url): url }
    }
    var diagnosticCode: String {
        switch self { case .access: "access_denied"; case .missing: "file_missing"; case .invalid: "unreadable_or_invalid" }
    }
    var needsAccess: Bool { if case .access = self { true } else { false } }
    func description(_ lang: Lang) -> String {
        let key: L10n.Key = switch self {
        case .access: .configNeedsAccess
        case .missing: .configMissing
        case .invalid: .configUnreadable
        }
        return L10n.text(key, lang, target.lastPathComponent)
    }
    static func classify(_ error: Error, at file: URL) -> ConfigReadIssue {
        let target = SSHConfig.realTarget(file)
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain {
            if [Int(EACCES), Int(EPERM)].contains(value.code) { return .access(target) }
            if value.code == Int(ENOENT) { return .missing(target) }
        }
        if value.domain == NSCocoaErrorDomain {
            if value.code == NSFileReadNoPermissionError { return .access(target) }
            if [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code) { return .missing(target) }
        }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error {
            let issue = classify(underlying, at: file)
            if case .invalid = issue {} else { return issue }
        }
        return .invalid(target)
    }
}

enum SSHConfig {
    static func requiresCommandTrust(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let parts = tokens(line)
            guard let key = parts.first?.lowercased() else { return false }
            if ["proxycommand", "knownhostscommand"].contains(key) {
                return parts.count > 1 && parts[1].lowercased() != "none"
            }
            return key == "match" && parts.dropFirst().contains { ["exec", "!exec"].contains($0.lowercased()) }
        }
    }

    static func trustDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func realTarget(_ file: URL) -> URL {
        var target = file.standardizedFileURL
        for _ in 0..<32 {
            guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) else {
                return target.resolvingSymlinksInPath()
            }
            target = (link.hasPrefix("/") ? URL(fileURLWithPath: link) : target.deletingLastPathComponent().appendingPathComponent(link)).standardizedFileURL
        }
        return target
    }

    static func isSafeAlias(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.contains(where: { $0.isWhitespace || $0.isNewline || "/*?!%\\\"'".contains($0) })
    }

    /// Lex ssh_config tokens without executing Match exec or shell substitutions.
    static func tokens(_ line: String) -> [String] {
        var result: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for char in line {
            if escaped { word.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if let current = quote {
                if char == current { quote = nil } else { word.append(char) }
            } else if char == "\"" || char == "'" { quote = char }
            else if char == "#" { break }
            else if char.isWhitespace || (char == "=" && (result.isEmpty || (result.count == 1 && word.isEmpty))) {
                if !word.isEmpty { result.append(word); word = "" }
            } else { word.append(char) }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }

    static func parseHosts(_ text: String, selfAliases: Set<String> = []) -> [String] {
        var result: [String] = []
        let excluded = selfAliases.union(localAliases(in: text))
        for line in text.components(separatedBy: .newlines) {
            let parts = tokens(line)
            guard parts.first?.lowercased() == "host" else { continue }
            // Keep comma-separated aliases accepted by older pmap versions.
            for name in parts.dropFirst().flatMap({ $0.split(separator: ",").map(String.init) }) {
                if isSafeAlias(name), !name.contains("."), !excluded.contains(name), !result.contains(name) { result.append(name) }
            }
        }
        return result
    }

    // Inspect only Host/HostName text; never execute Match exec or ssh -G to build the list.
    private static func localAliases(in text: String) -> Set<String> {
        let lines = text.components(separatedBy: .newlines).map(tokens)
        let aliases = lines.filter { $0.first?.lowercased() == "host" }
            .flatMap { $0.dropFirst().flatMap { $0.split(separator: ",").map(String.init) } }
            .filter { isSafeAlias($0) && !$0.contains(".") }
        var local: Set<String> = []
        for alias in Set(aliases) {
            var matches = true
            for parts in lines {
                guard let key = parts.first?.lowercased() else { continue }
                if key == "host" {
                    let patterns = parts.dropFirst().flatMap { $0.split(separator: ",").map(String.init) }
                    func match(_ pattern: String) -> Bool { fnmatch(pattern.lowercased(), alias.lowercased(), 0) == 0 }
                    matches = patterns.contains { !$0.hasPrefix("!") && match($0) }
                        && !patterns.contains { $0.hasPrefix("!") && match(String($0.dropFirst())) }
                } else if key == "match" {
                    matches = false
                } else if key == "hostname", matches, parts.count > 1 {
                    if ["localhost", "127.0.0.1", "::1"].contains(parts[1].lowercased()) { local.insert(alias) }
                    break // OpenSSH uses the first applicable value.
                }
            }
        }
        return local
    }

    static func readHosts(at file: URL) throws -> [String] {
        parseHosts(try readText(at: file))
    }

    static func readText(at file: URL) throws -> String {
        var visited: Set<String> = []
        var expandedLines: [String] = []
        func read(_ url: URL, depth: Int) throws {
            guard depth < 16, visited.count < 256 else { throw CocoaError(.fileReadTooLarge) }
            let path = url.standardizedFileURL.path
            guard visited.insert(path).inserted else { return }
            let text: String
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? 0 < 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
                text = try String(contentsOfFile: path, encoding: .utf8)
            } catch { throw ConfigReadIssue.classify(error, at: url) }
            for line in text.components(separatedBy: .newlines) {
                let parts = tokens(line)
                guard let key = parts.first?.lowercased() else { continue }
                if key == "include" {
                    for pattern in parts.dropFirst() {
                        let expanded = pattern.hasPrefix("~/") ? AppPaths.sshHome.path + String(pattern.dropFirst()) : pattern
                        let absolute = expanded.hasPrefix("/") ? expanded : AppPaths.sshHome.appendingPathComponent(".ssh/" + expanded).path
                        var matches = glob_t()
                        let status = glob(absolute, GLOB_ERR, nil, &matches)
                        defer { globfree(&matches) }
                        if status == GLOB_NOMATCH { continue }
                        guard status == 0 else { throw ConfigReadIssue.access(URL(fileURLWithPath: absolute).deletingLastPathComponent()) }
                        if let paths = matches.gl_pathv {
                            for index in 0..<Int(matches.gl_pathc) {
                                if let entry = paths[index] { try read(URL(fileURLWithPath: String(cString: entry)), depth: depth + 1) }
                            }
                        }
                    }
                } else { expandedLines.append(line) }
            }
        }
        try read(file, depth: 0)
        return expandedLines.joined(separator: "\n")
    }

    /// Static inspection only: preflight must not execute untrusted Match exec.
    static func knownHostsFiles(in text: String, hosts: [String], home: URL) -> [URL] {
        var result: [URL] = []
        for host in hosts.isEmpty ? [""] : hosts {
            var applies = true
            var configured: [String]?
            var hostname = host
            var port = "22"
            var user = NSUserName()
            var foundHostname = false, foundPort = false, foundUser = false
            for line in text.components(separatedBy: .newlines) {
                let parts = tokens(line)
                guard let key = parts.first?.lowercased() else { continue }
                if key == "host" {
                    let patterns = parts.dropFirst().flatMap { $0.split(separator: ",").map(String.init) }
                    func matches(_ value: String) -> Bool { fnmatch(value.lowercased(), host.lowercased(), 0) == 0 }
                    applies = patterns.contains { !$0.hasPrefix("!") && matches($0) }
                        && !patterns.contains { $0.hasPrefix("!") && matches(String($0.dropFirst())) }
                } else if key == "match" { applies = false }
                else if applies, parts.count > 1 {
                    switch key {
                    case "userknownhostsfile": if configured == nil { configured = Array(parts.dropFirst()) }
                    case "hostname": if !foundHostname { hostname = parts[1]; foundHostname = true }
                    case "port": if !foundPort { port = parts[1]; foundPort = true }
                    case "user": if !foundUser { user = parts[1]; foundUser = true }
                    default: break
                    }
                }
            }
            for raw in configured ?? [home.appendingPathComponent(".ssh/known_hosts").path] {
                if raw.lowercased() == "none" { continue }
                var value = raw
                for (token, replacement) in [("%d", home.path), ("%h", hostname), ("%n", host), ("%p", port), ("%r", user), ("%u", NSUserName())] {
                    value = value.replacingOccurrences(of: token, with: replacement)
                }
                if value.hasPrefix("~/") { value = home.path + value.dropFirst() }
                // Unknown tokens/environment expansion are left to OpenSSH at connection time.
                guard !value.contains("%"), !value.contains("${") else { continue }
                let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : home.appendingPathComponent(value)
                if !result.contains(url.standardizedFileURL) { result.append(url.standardizedFileURL) }
            }
        }
        return result
    }

    static func listHosts() -> [String] {
        (try? readHosts(at: AppPaths.sshHome.appendingPathComponent(".ssh/config"))) ?? []
    }

    static func resolve(_ alias: String) -> SSHTarget? {
        guard isSafeAlias(alias), let out = Shell.run("/usr/bin/ssh", ["-G", "-o", "PermitLocalCommand=no", "--", alias]) else { return nil }
        var target = SSHTarget(alias: alias)
        for line in out.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "user": target.user = parts[1]
            case "hostname": target.hostname = parts[1]
            case "port": target.port = Int(parts[1]) ?? 22
            case "proxyjump": target.proxyJump = parts[1]
            case "identityfile": if target.identityFile.isEmpty { target.identityFile = parts[1] }
            default: break
            }
        }
        return target.hostname.isEmpty ? nil : target
    }
}
