// Pmap.swift
// 菜单栏端口映射工具 —— 复用 SSH ControlMaster 连接的端口转发开关
//
// 构建: ./build.sh
// 运行: ./pmap.app

import SwiftUI
import AppKit
import Combine

// MARK: - 模型

struct Rule: Codable, Hashable, Identifiable {
    var local: Int
    var remote: Int
    var id: Int { local }

    var label: String { local == remote ? "\(local)" : "\(local):\(remote)" }
}

struct Group: Codable, Identifiable {
    var name: String
    var desc: String = ""
    var rules: [Rule] = []
    var id: String { name }
}

struct Config: Codable {
    var host: String = ""
    var groups: [Group] = []
    /// 从面板移除的主机（仅面板层隐藏，绝不修改 ~/.ssh/config）
    var hiddenHosts: [String]? = nil
}

/// `ssh -G <host>` 展开出的连接参数
struct SSHTarget: Equatable {
    var alias: String
    var user: String = ""
    var hostname: String = ""
    var port: Int = 22
    var proxyJump: String = ""
    var identityFile: String = ""

    /// 别名未在 ~/.ssh/config 中定义时，ssh -G 会把字符串原样当 hostname
    var aliasDefined: Bool { !hostname.isEmpty && hostname != alias }
}

enum HostConn: Equatable {
    case off          // 灰：未连接
    case connecting   // 灰：连接中
    case on           // 绿：已连接
    case failed       // 红：连接失败
}

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

// MARK: - Shell

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static func ssh(_ args: [String]) -> (code: Int32, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "\(error)") }
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: e, encoding: .utf8) ?? "")
    }

    /// 本地端口是否被占用
    static func portBusy(_ port: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard !text.isEmpty else { return nil }
        // 解析进程名
        for line in text.components(separatedBy: .newlines).dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count > 1 { return parts[1] }
        }
        return "unknown"
    }
}

// MARK: - 隧道管理

enum Tunnel {
    /// 程序专用的 ControlPath，不依赖 ~/.ssh/config 里是否启用了 ControlMaster。
    /// 所有 ssh 调用统一走这条 socket，实现连接复用 —— 这是「秒开/秒关」的关键。
    /// 说明：ControlPath 里的 `%h` 若包含 `/` 会展开成多层目录，故这里显式用 host 拼路径。
    static func controlPath(for host: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = home + "/.ssh/pmap-control"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/\(host)"
    }

    /// 统一的 ssh 控制参数。ControlPersist 让主连接在空闲后仍保留，避免重复握手。
    private static func controlArgs(_ host: String) -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath(for: host))",
            "-o", "ControlPersist=yes",
        ]
    }

    static func forward(host: String, _ r: Rule) -> String? {
        let (code, err) = Shell.ssh(controlArgs(host) + ["-O", "forward", "-L", "127.0.0.1:\(r.local):127.0.0.1:\(r.remote)", host])
        return code == 0 ? nil : clean(err)
    }

    static func cancel(host: String, _ r: Rule) -> String? {
        let (code, err) = Shell.ssh(controlArgs(host) + ["-O", "cancel", "-L", "127.0.0.1:\(r.local):127.0.0.1:\(r.remote)", host])
        return code == 0 ? nil : clean(err)
    }

    static func check(host: String) -> Bool {
        let (code, _) = Shell.ssh(controlArgs(host) + ["-O", "check", host])
        return code == 0
    }

    /// 断开 ControlMaster 主连接（单击已连接主机 = 断开）
    static func shutdown(host: String) {
        _ = Shell.ssh(controlArgs(host) + ["-O", "exit", host])
    }

    static func ensureConnection(host: String) -> String? {
        if check(host: host) { return nil }
        // 用 -M 显式建立主连接（ControlMaster 由 controlArgs 统一为 auto，-M 强制作为 master）。
        // 不再依赖 ssh config 的 ControlPersist。
        let (code, err) = Shell.ssh(controlArgs(host) + ["-f", "-N", host])
        if code != 0 { return clean(err) }
        for _ in 0..<20 {
            if check(host: host) { return nil }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return "SSH 连接建立超时"
    }

    private static func clean(_ s: String) -> String {
        s.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "未知错误"
    }
}

// MARK: - 存储

@MainActor
final class Store: ObservableObject {
    @Published var config = Config()
    @Published var hostState: [String: HostConn] = [:]  // 各主机连接状态
    @Published var activeHost: String?                  // 当前已连接（绿）的主机
    @Published var active: Set<Int> = []                // 已开启的本地端口
    @Published var adhoc: [Rule] = []                   // 临时端口
    @Published var errors: [Int: String] = [:]          // 端口 -> 错误
    @Published var busy = false
    @Published var quickInput = ""
    @Published var inputInvalid = false                 // 万能输入格式错误（输入框红显）

    @Published var hostAliases: [String] = []

    /// 面板上显示的主机 = ssh config 全集 - 已移除（不动 ~/.ssh/config）
    var hiddenHosts: Set<String> { Set(config.hiddenHosts ?? []) }
    var visibleHosts: [String] { hostAliases.filter { !hiddenHosts.contains($0) } }

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pmap/config.json")
    }

    init() { load() }

    // 持久化
    func load() {
        let url = configURL
        if let d = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(Config.self, from: d) {
            config = c
        }
        refreshHosts()
    }

    func save() {
        let url = configURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let d = try? JSONEncoder.pretty.encode(config) { try? d.write(to: url) }
    }

    /// 重新扫描 ~/.ssh/config 的主机列表（恢复到面板显示），并刷新连接状态
    private func refreshHosts() {
        hostAliases = SSHConfig.listHosts()
        for h in visibleHosts where hostState[h] == nil { hostState[h] = .off }
    }

    /// 重新载入配置：重读 ~/.ssh/config + 重读本程序配置文件，
    /// 并清空「已移除」记录 —— 恢复所有被双击移除的 Host
    func reloadFromDisk() {
        let curHost = config.host
        let curActive = activeHost
        config = Config()
        let url = configURL
        if let d = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(Config.self, from: d) {
            config = c
        }
        config.hiddenHosts = nil          // 恢复全部被移除的 Host
        config.host = curHost
        refreshHosts()
        for h in visibleHosts where hostState[h] == nil { hostState[h] = .off }
        // 若当前活动主机已不在（被用户从 ssh config 删除），断开并复位
        if let h = curActive, !visibleHosts.contains(h) {
            active.removeAll()
            errors.removeAll()
            hostState[h] = .off
            activeHost = nil
        }
        save()
    }

    var allRules: [Rule] { config.groups.flatMap(\.rules) + adhoc }

    func isOn(_ r: Rule) -> Bool { active.contains(r.local) }
    func error(_ r: Rule) -> String? { errors[r.local] }

    var onCount: Int { allRules.filter { active.contains($0.local) }.count }

    /// 当前可操作转发的主机（必须处于已连接状态）
    private var connHost: String? {
        guard let h = activeHost, hostState[h] == .on else { return nil }
        return h
    }

    // MARK: 主机连接（单击切换 连接/断开）

    /// 单击主机：已连接则断开（变灰）；否则连接（成功绿/失败红）。
    /// 换主机时，旧主机自动断开变灰。
    func toggleHost(_ alias: String) {
        if activeHost == alias {
            if hostState[alias] == .on { disconnectHost(alias) }
            return   // connecting 中不重复触发
        }
        if let cur = activeHost { disconnectHost(cur) }
        connectHost(alias)
    }

    private func connectHost(_ alias: String) {
        hostState[alias] = .connecting
        activeHost = alias
        config.host = alias
        save()
        Task {
            let e = await Task.detached { Tunnel.ensureConnection(host: alias) }.value
            if e != nil {
                hostState[alias] = .failed
            } else {
                hostState[alias] = .on
            }
        }
    }

    private func disconnectHost(_ alias: String) {
        let ports = allRules.filter { active.contains($0.local) }
        active.removeAll()
        errors.removeAll()
        hostState[alias] = .off
        if activeHost == alias { activeHost = nil }
        Task.detached {
            for r in ports { _ = Tunnel.cancel(host: alias, r) }
            Tunnel.shutdown(host: alias)
        }
    }

    /// 双击主机：从面板移除（仅隐藏，绝不修改 ~/.ssh/config）
    func hideHost(_ alias: String) {
        if activeHost == alias { disconnectHost(alias) }
        var h = config.hiddenHosts ?? []
        if !h.contains(alias) { h.append(alias) }
        config.hiddenHosts = h
        save()
    }

    // 单条切换
    func toggle(_ r: Rule) {
        if active.contains(r.local) { close(r) } else { open(r) }
    }

    func open(_ r: Rule) {
        guard let host = connHost else { return }
        busy = true
        Task {
            defer { busy = false }
            // 阻塞的 lsof / ssh 全部在后台线程跑，避免卡死 UI
            let result = await Task.detached { () -> (busyBy: String?, fwdErr: String?) in
                if let busyBy = Shell.portBusy(r.local) {
                    return (busyBy, nil)
                }
                return (nil, Tunnel.forward(host: host, r))
            }.value

            if let busyBy = result.busyBy {
                errors[r.local] = "本地 \(r.local) 被 \(busyBy) 占用"
                return
            }
            if let e = result.fwdErr {
                errors[r.local] = e
            } else {
                errors[r.local] = nil
                active.insert(r.local)
            }
        }
    }

    func close(_ r: Rule) {
        guard let host = connHost else { return }
        busy = true
        Task {
            defer { busy = false }
            await Task.detached { _ = Tunnel.cancel(host: host, r) }.value
            active.remove(r.local)
            errors[r.local] = nil
        }
    }

    /// 整组切换：全开则全关，否则整组开（fail-fast，失败回滚）
    func toggleGroup(_ g: Group) {
        let rs = g.rules
        guard connHost != nil, !rs.isEmpty else { return }
        if rs.allSatisfy({ active.contains($0.local) }) { rs.forEach { close($0) } }
        else { openGroup(rs.filter { !active.contains($0.local) }) }
    }

    func openGroup(_ rs: [Rule]) {
        guard let host = connHost, !rs.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            let outcome = await Task.detached { () -> (opened: [Rule], failed: Rule?, err: String?) in
                var opened: [Rule] = []
                for r in rs {
                    if let by = Shell.portBusy(r.local) {
                        opened.forEach { _ = Tunnel.cancel(host: host, $0) }
                        return (opened, r, "本地 \(r.local) 被 \(by) 占用")
                    }
                    if let e = Tunnel.forward(host: host, r) {
                        opened.forEach { _ = Tunnel.cancel(host: host, $0) }
                        return (opened, r, e)
                    }
                    opened.append(r)
                }
                return (opened, nil, nil)
            }.value

            if let r = outcome.failed, let e = outcome.err {
                errors[r.local] = e
                outcome.opened.forEach { active.remove($0.local) }
                return
            }
            for r in outcome.opened {
                errors[r.local] = nil
                active.insert(r.local)
            }
        }
    }

    // 万能入口解析：port @组名 或 local_port:remote_port @组名
    // 无组名 → 落入「临时」；组不存在则自动创建
    func parseQuick(_ s: String) -> (rule: Rule, group: String?)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var portPart = t
        var group: String? = nil
        if let at = t.firstIndex(of: "@") {
            portPart = String(t[..<at]).trimmingCharacters(in: .whitespaces)
            let g = String(t[t.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            group = g.isEmpty ? nil : g
        }
        guard !portPart.isEmpty, !portPart.contains(" ") else { return nil }
        if portPart.contains(":") {
            let p = portPart.split(separator: ":").map(String.init)
            guard p.count == 2, let l = Int(p[0]), let r = Int(p[1]), isValid(l), isValid(r) else { return nil }
            return (Rule(local: l, remote: r), group)
        }
        guard let l = Int(portPart), isValid(l) else { return nil }
        return (Rule(local: l, remote: l), group)
    }

    private func isValid(_ p: Int) -> Bool { p > 0 && p < 65536 }

    static var usageHint: String { "格式：port @组名 或 port:port @组名" }

    func commitQuick() {
        guard let (rule, group) = parseQuick(quickInput) else {
            // 不弹出任何文字破坏面板：清空输入，输入框内红色高亮格式提示
            quickInput = ""
            inputInvalid = true
            return
        }

        let targetName = group          // nil = 临时组
        let samePort = { (r: Rule) in r.local == rule.local }   // 按端口（local）判同

        // 1. 目标位置是否已有「完全一致」的规则（同端口同目标）→ 不变
        if targetName == nil {
            if adhoc.contains(where: samePort) {
                quickInput = ""; inputInvalid = false; save()
                return
            }
        } else if let idx = config.groups.firstIndex(where: { $0.name == targetName }) {
            if config.groups[idx].rules.contains(where: samePort) {
                quickInput = ""; inputInvalid = false; save()
                return
            }
        }

        // 2. 该端口是否已在别的组（含临时）→ 移出旧组（状态随端口迁移）
        for i in config.groups.indices {
            config.groups[i].rules.removeAll(where: samePort)
        }
        config.groups.removeAll { $0.rules.isEmpty }
        adhoc.removeAll(where: samePort)

        // 3. 落到目标组（不存在则新建）
        if let g = targetName {
            if let idx = config.groups.firstIndex(where: { $0.name == g }) {
                config.groups[idx].rules.append(rule)
            } else {
                config.groups.append(Group(name: g, rules: [rule]))
            }
        } else {
            adhoc.append(rule)
        }

        quickInput = ""
        inputInvalid = false
        save()
        // 端口已开启则保持开启状态（active/errors 已随迁移保留），否则开启
        if !active.contains(rule.local) { open(rule) }
    }

    func removeRule(_ r: Rule, from g: Group) {
        guard let idx = config.groups.firstIndex(where: { $0.name == g.name }) else { return }
        config.groups[idx].rules.removeAll { $0 == r }
        if config.groups[idx].rules.isEmpty { config.groups.remove(at: idx) }
        if active.contains(r.local) { close(r) }
        save()
    }

    func removeAdhoc(_ r: Rule) {
        adhoc.removeAll { $0 == r }
        if active.contains(r.local) { close(r) }
    }

    /// 双击「临时」组：清空全部临时端口
    func clearAdhoc() {
        let rs = adhoc
        adhoc.removeAll()
        guard let host = connHost else { return }
        for r in rs { active.remove(r.local); errors[r.local] = nil }
        Task.detached {
            for r in rs { _ = Tunnel.cancel(host: host, r) }
        }
    }

    /// 双击组名：删除该组
    func removeGroup(_ g: Group) {
        let rs = g.rules
        config.groups.removeAll { $0.name == g.name }
        save()
        guard let host = connHost else { return }
        for r in rs { active.remove(r.local); errors[r.local] = nil }
        Task.detached {
            for r in rs { _ = Tunnel.cancel(host: host, r) }
        }
    }
}

// MARK: - 视图

/// 统一按钮状态色：绿=通，灰=不通，红=故障
enum PillState {
    case off, on, failed
}

/// 统一按钮风格：文字 + 圆角矩形框
struct Pill: View {
    let text: String
    let state: PillState

    private var fill: Color {
        switch state {
        case .off: return Color.secondary.opacity(0.08)
        case .on: return Color.green.opacity(0.16)
        case .failed: return Color.red.opacity(0.14)
        }
    }
    private var border: Color {
        switch state {
        case .off: return Color.secondary.opacity(0.28)
        case .on: return Color.green.opacity(0.55)
        case .failed: return Color.red.opacity(0.6)
        }
    }
    private var fg: Color {
        switch state {
        case .off: return Color.secondary
        case .on: return Color.green
        case .failed: return Color.red
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: state == .off ? .regular : .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 端口 chip：单击开关，双击删除；绿=通，灰=不通，红=故障
struct Chip: View {
    let rule: Rule
    let on: Bool
    let err: String?
    let action: () -> Void
    let remove: () -> Void

    private var fgColor: Color {
        if err != nil { return .red }
        return on ? .primary : .secondary
    }
    private var fillColor: Color {
        if err != nil { return Color.red.opacity(0.12) }
        if on { return Color.green.opacity(0.14) }
        return Color.secondary.opacity(0.06)
    }
    private var borderColor: Color {
        if err != nil { return Color.red.opacity(0.6) }
        if on { return Color.green.opacity(0.5) }
        return Color.secondary.opacity(0.28)
    }
    private var hint: String {
        if let e = err { return e }
        return on ? "单击关闭 · 双击删除" : "单击开启 · 双击删除"
    }

    var body: some View {
        Text(rule.label)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(fgColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(fillColor))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(borderColor, lineWidth: 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onTapGesture(count: 2) { remove() }
            .onTapGesture(count: 1) { action() }
            .help(hint)
    }
}

/// 组行：组名按钮（单击全组开关，双击删组）+ 端口 chips
struct GroupRow: View {
    @ObservedObject var store: Store
    let group: Group
    let adhocGroup: Bool

    private var onCount: Int { group.rules.filter { store.active.contains($0.local) }.count }
    private var allOn: Bool { !group.rules.isEmpty && onCount == group.rules.count }
    private var anyFailed: Bool { group.rules.contains { store.error($0) != nil } }

    private var groupState: PillState {
        if allOn { return .on }
        if anyFailed { return .failed }
        return .off
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Pill(text: group.name, state: groupState)
                .onTapGesture(count: 2) {
                    adhocGroup ? store.clearAdhoc() : store.removeGroup(group)
                }
                .onTapGesture(count: 1) { store.toggleGroup(group) }
                .help(adhocGroup ? "单击全组开关 · 双击清空临时端口"
                      : "单击全组开关 · 双击删除该组")

            if !group.rules.isEmpty {
                FlowRow(spacing: 4) {
                    ForEach(group.rules) { r in
                        Chip(rule: r, on: store.isOn(r), err: store.error(r),
                             action: { store.toggle(r) },
                             remove: { adhocGroup ? store.removeAdhoc(r)
                                      : store.removeRule(r, from: group) })
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// 简易流式布局：端口 chip 自动换行
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var store: Store
    @FocusState var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主机（单击连接/断开，双击移除）
            VStack(alignment: .leading, spacing: 6) {
                if store.visibleHosts.isEmpty {
                    Text("~/.ssh/config 里没有可用主机")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .padding(.vertical, 4)
                } else {
                    FlowRow(spacing: 5) {
                        ForEach(store.visibleHosts, id: \.self) { alias in
                            hostButton(alias)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)

            Divider()

            // 组（组名单击全组开关/双击删组；端口单击开关/双击删除）
            VStack(alignment: .leading, spacing: 8) {
                if store.config.groups.isEmpty && store.adhoc.isEmpty {
                    Text("在下方输入 3000 @web 建组并加端口")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                }
                ForEach(store.config.groups) { g in
                    GroupRow(store: store, group: g, adhocGroup: false)
                }
                if !store.adhoc.isEmpty {
                    GroupRow(store: store,
                             group: Group(name: "临时", rules: store.adhoc),
                             adhocGroup: true)
                }
            }
            .padding(.horizontal, 0).padding(.vertical, 9)

            Divider()

            // 万能输入框（唯一入口；格式错误在框内红色提示，不弹出文字）
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField("", text: $store.quickInput,
                          prompt: Text(Store.usageHint)
                              .font(.system(size: 11, design: .monospaced))
                              .foregroundColor(store.inputInvalid ? .red : .secondary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(store.inputInvalid ? Color.red : Color.primary)
                    .focused($inputFocused)
                    .onSubmit { store.commitQuick() }
                    .onChange(of: store.quickInput) { _, nv in
                        if !nv.isEmpty { store.inputInvalid = false }
                    }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(store.inputInvalid ? Color.red.opacity(0.6) : Color.secondary.opacity(0.2),
                              lineWidth: 0.8))
            .padding(.horizontal, 10).padding(.vertical, 9)
            .onAppear { inputFocused = true }

            Divider()

            // 动作
            VStack(spacing: 1) {
                row("重新载入配置", "") { store.reloadFromDisk() }
                Divider().padding(.vertical, 3)
                row("退出", "⌘Q") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .frame(width: 360)
    }

    /// 主机按钮：单击连接/断开，双击从面板移除（不改 ~/.ssh/config）
    private func hostButton(_ alias: String) -> some View {
        let st = store.hostState[alias] ?? .off
        let state: PillState = st == .on ? .on : (st == .failed ? .failed : .off)
        return Pill(text: alias, state: state)
            .onTapGesture(count: 2) { store.hideHost(alias) }
            .onTapGesture(count: 1) { store.toggleHost(alias) }
            .help("单击连接/断开 · 双击从面板移除")
    }

    private func row(_ t: String, _ k: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            HStack {
                Text(t).font(.system(size: 12))
                Spacer()
                Text(k).font(.system(size: 11)).foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, opacity: 1)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

// MARK: - App

/// 开发期离屏渲染，便于在没有屏幕录制权限时目检布局
enum Snapshot {
    @MainActor
    static func write<V: View>(_ view: V, to path: String) {
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("已写入 \(path)  尺寸 \(Int(img.size.width))x\(Int(img.size.height))")
    }
}

extension Store {
    static var shared: Store?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var countObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let store = Store.shared else { return }

        // 菜单栏图标 + 转发计数
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let btn = item.button {
            let img = NSImage(systemSymbolName: "arrow.left.arrow.right",
                              accessibilityDescription: "pmap")
            img?.isTemplate = true
            btn.image = img
            btn.action = #selector(togglePopover(_:))
            btn.target = self
        }
        // onCount 是计算属性（依赖 active/config/adhoc），合并监听这些来源的变化
        let any = store.$active.map { _ in () }.eraseToAnyPublisher()
        let cfg = store.$config.map { _ in () }.eraseToAnyPublisher()
        let adh = store.$adhoc.map { _ in () }.eraseToAnyPublisher()
        countObserver = Publishers.MergeMany(any, cfg, adh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let store = Store.shared else { return }
                self.statusItem?.button?.title = store.onCount > 0 ? " \(store.onCount)" : ""
            }

        // 弹出面板
        popover.behavior = .transient          // 点击面板外自动关闭，行为同菜单
        let vc = NSHostingController(rootView: MenuPanel(store: store).frame(width: 360))
        vc.sizingOptions = .preferredContentSize   // 自适应内容高度，避免截断
        popover.contentSize = NSSize(width: 360, height: 640)
        popover.contentViewController = vc
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let btn = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@main
struct PmapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        Store.shared = Store()
        // 自检入口：`pmap.app/Contents/MacOS/pmap --list-hosts`
        if CommandLine.arguments.contains("--list-hosts") {
            let hosts = SSHConfig.listHosts()
            print("共 \(hosts.count) 台主机")
            for h in hosts { print("  " + h) }
            exit(0)
        }
        // 离屏渲染面板，用于开发期目检布局：--snapshot <输出路径>
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
           i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            Snapshot.write(MenuPanel(store: Store()), to: out + ".png")
            exit(0)
        }
        // 真实渲染导出（非 ImageRenderer）：在深色窗口里用真实 AppKit 渲染面板，
        // 再抓取本进程窗口写成 PNG，用于像素级验证：--render <输出路径>
        if let i = CommandLine.arguments.firstIndex(of: "--render"),
           i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 700),
                                   styleMask: [.titled],
                                   backing: .buffered, defer: false)
                win.title = "pmap render"
                win.appearance = NSAppearance(named: .darkAqua)
                let host = NSHostingView(rootView: MenuPanel(store: Store.shared!))
                win.contentView = host
                win.center()
                win.makeKeyAndOrderFront(nil)
                // 用视图自身的离屏缓存渲染，拿真实像素（不受窗口遮挡影响）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    host.frame = NSRect(x: 0, y: 0, width: 360, height: host.fittingSize.height)
                    win.setContentSize(host.frame.size)
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        print("缓存渲染失败"); exit(0)
                    }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: out))
                        print("已写入 \(out)  尺寸 \(rep.pixelsWide)x\(rep.pixelsHigh)")
                    }
                    exit(0)
                }
            }
        }
        // 调试模式：面板放进普通窗口，便于人工目检（--panel）
        if CommandLine.arguments.contains("--panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 760),
                                   styleMask: [.titled],
                                   backing: .buffered, defer: false)
                win.title = "pmap 调试"
                win.appearance = NSAppearance(named: .darkAqua)
                win.contentView = NSHostingView(rootView: MenuPanel(store: Store.shared!))
                win.center()
                win.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    var body: some Scene {
        Settings { EmptyView() }   // 仅作场景占位，UI 全部由 AppDelegate 管理
    }
}
