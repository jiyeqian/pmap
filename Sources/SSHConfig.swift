// SSHConfig.swift
// 解析 ~/.ssh/config 与 ssh -G 展开结果

import Foundation

// MARK: - SSH 配置解析

enum SSHConfig {
    static func listHosts() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = home + "/.ssh/config"
        return parseHosts((try? String(contentsOfFile: path, encoding: .utf8)) ?? "", selfAliases: localAliases())
    }

    /// 解析 ssh_config 文本，收集所有具体主机别名
    /// - 跳过通配符（`*` `?` `!`）与含点的地址
    /// - 跳过会在 `ssh -G` 里解析成自身的条目
    static func parseHosts(_ text: String, selfAliases: Set<String> = []) -> [String] {
        var hosts: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Host / HostName / HostKeyAlias 都可能是 "host" 开头，按空白切分后精确比对
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let key = parts.first?.lowercased(), key == "host" else { continue }
            guard parts.count > 1 else { continue }

            for token in parts.dropFirst() {
                // ssh_config 允许 `Host a b c` 一行多个别名，也允许逗号分隔
                for rawName in token.split(separator: ",").map(String.init) {
                    let name = rawName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { continue }
                    // 通配、否定、含点（多为直接写地址）
                    if name.contains(where: { "*?!".contains($0) }) { continue }
                    if name.contains(".") { continue }
                    if selfAliases.contains(name) { continue }
                    if !hosts.contains(name) { hosts.append(name) }
                }
            }
        }
        return hosts
    }

    /// 跳过指向本机的条目（通常没人想给自己开隧道）
    private static func localAliases() -> Set<String> {
        var out: Set<String> = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = home + "/.ssh/config"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return out }

        var current: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count > 1 else { continue }
            switch parts[0].lowercased() {
            case "host":
                current = parts[1]
            case "hostname":
                let h = parts[1].lowercased()
                if h == "localhost" || h == "127.0.0.1" || h == "::1" { if let c = current { out.insert(c) } }
            default: break
            }
        }
        return out
    }

    /// 用 ssh -G 展开别名，得到最终生效的连接参数
    static func resolve(_ alias: String) -> SSHTarget? {
        guard let out = Shell.run("/usr/bin/ssh", ["-G", alias]) else { return nil }
        var t = SSHTarget(alias: alias)
        for line in out.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "user": t.user = parts[1]
            case "hostname": t.hostname = parts[1]
            case "port": t.port = Int(parts[1]) ?? 22
            case "proxyjump": t.proxyJump = parts[1]
            case "identityfile": if t.identityFile.isEmpty { t.identityFile = parts[1] }
            default: break
            }
        }
        guard !t.hostname.isEmpty else { return nil }
        return t
    }
}
