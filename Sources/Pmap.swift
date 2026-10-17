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

enum ConnState: Equatable {
    case disconnected
    case connecting
    case connected(since: Date)
    case failed(String)
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

    /// 批量探测哪些别名已有 ControlMaster 连接（阻塞，需在后台线程调用）
    static func online(_ aliases: [String]) -> Set<String> {
        var alive: Set<String> = []
        for a in aliases where check(host: a) { alive.insert(a) }
        return alive
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
    @Published var conn: ConnState = .disconnected
    @Published var active: Set<Int> = []          // 已开启的本地端口
    @Published var adhoc: [Rule] = []            // 临时端口
    @Published var errors: [Int: String] = [:]   // 端口 -> 错误
    @Published var busy = false
    @Published var quickInput = ""
    @Published var focusQuickSignal = 0        // 递增触发万能输入框聚焦
    @Published var lastHint: String?
    @Published var onlineHosts: Set<String> = []   // 已探测到在线的别名（异步缓存）

    let hostAliases = SSHConfig.listHosts()
    private var _target: SSHTarget?
    private var _targetHost: String = ""
    /// 解析当前主机连接参数（带缓存，仅主机变化时重新 `ssh -G`）
    var target: SSHTarget? {
        if _targetHost != config.host {
            _targetHost = config.host
            _target = config.host.isEmpty ? nil : SSHConfig.resolve(config.host)
        }
        return _target
    }

    var availableHosts: [String] { hostAliases }

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
        if config.host.isEmpty, let first = hostAliases.first { config.host = first }
        refreshConnection()
    }

    func save() {
        let url = configURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let d = try? JSONEncoder.pretty.encode(config) { try? d.write(to: url) }
    }

    func reloadFromDisk() { load() }

    var allRules: [Rule] { config.groups.flatMap(\.rules) + adhoc }

    func rules(in g: Group) -> [Rule] { g.rules }

    func isOn(_ r: Rule) -> Bool { active.contains(r.local) }
    func error(_ r: Rule) -> String? { errors[r.local] }

    var totalCount: Int { allRules.count }
    var onCount: Int { allRules.filter { active.contains($0.local) }.count }

    // 连接
    func refreshConnection() {
        guard !config.host.isEmpty else { conn = .disconnected; return }
        let host = config.host
        conn = .connecting
        Task {
            let ok = await Task.detached { Tunnel.check(host: host) }.value
            conn = ok ? .connected(since: Date()) : .disconnected
        }
    }

    /// 切换主机：先关掉旧主机的全部转发，再刷新连接状态
    func selectHost(_ alias: String) {
        guard alias != config.host else { return }
        // 同步清空旧主机的转发记录（旧连接的 socket 已随主机切换失效，无需逐条 cancel）
        active.removeAll()
        errors.removeAll()
        config.host = alias
        refreshConnection()
        save()
    }

    /// 后台探测各主机是否有现成 ControlMaster 连接。
    /// 绝不能放在 view 的 body 里同步跑：每台一次 ssh -G + ssh -O check，
    /// 八台就是十几个子进程，界面会整个卡住。
    func probeOnlineHosts() {
        let aliases = hostAliases
        Task {
            let alive = await Task.detached { Tunnel.online(aliases) }.value
            onlineHosts = alive
        }
    }

    var connLabel: String {
        switch conn {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .disconnected: return "未连接"
        case .failed(let m): return m
        }
    }

    var dotColor: String {
        switch conn {
        case .connected: return "#1D9E75"
        case .connecting: return "#EF9F27"
        case .failed: return "#E24B4A"
        case .disconnected: return "#888780"
        }
    }

    // 单条切换
    func toggle(_ r: Rule) {
        if active.contains(r.local) { close(r) } else { open(r) }
    }

    func open(_ r: Rule) {
        guard let host = config.host.isEmpty ? nil : config.host else { return }
        busy = true
        Task {
            defer { busy = false }
            // 阻塞的 ssh / lsof 全部在后台线程跑，避免卡死 UI
            let result = await Task.detached { () -> (connErr: String?, busyBy: String?, fwdErr: String?) in
                if let e = Tunnel.ensureConnection(host: host) {
                    return (e, nil, nil)
                }
                if let busyBy = Shell.portBusy(r.local) {
                    return (nil, busyBy, nil)
                }
                let fwdErr = Tunnel.forward(host: host, r)
                return (nil, nil, fwdErr)
            }.value

            if let e = result.connErr {
                errors[r.local] = e
                conn = .failed(e)
                return
            }
            conn = .connected(since: Date())
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
        guard !config.host.isEmpty else { return }
        let host = config.host
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
        if rs.isEmpty { return }
        if rs.allSatisfy({ active.contains($0.local) }) { rs.forEach { close($0) } }
        else { openGroup(rs) }
    }

    func openGroup(_ rs: [Rule]) {
        guard !config.host.isEmpty else { return }
        let host = config.host
        busy = true
        Task {
            defer { busy = false }
            let outcome = await Task.detached { () -> (opened: [Rule], failed: Rule?, err: String?, rollback: Int) in
                if let e = Tunnel.ensureConnection(host: host) {
                    return ([], nil, e, 0)
                }
                var opened: [Rule] = []
                for r in rs {
                    if let by = Shell.portBusy(r.local) {
                        opened.forEach { _ = Tunnel.cancel(host: host, $0) }
                        return (opened, r, "本地 \(r.local) 被 \(by) 占用", opened.count)
                    }
                    if let e = Tunnel.forward(host: host, r) {
                        opened.forEach { _ = Tunnel.cancel(host: host, $0) }
                        return (opened, r, e, opened.count)
                    }
                    opened.append(r)
                }
                return (opened, nil, nil, 0)
            }.value

            if let e = outcome.err {
                // 连接失败（没有任何 opened，failed 为空）或某条失败（已回滚）
                if outcome.failed == nil {
                    conn = .failed(e)
                    rs.forEach { errors[$0.local] = e }
                } else if let r = outcome.failed {
                    errors[r.local] = e
                    outcome.opened.forEach { active.remove($0.local) }
                    if outcome.rollback > 0 { lastHint = "已回滚本组 \(outcome.rollback) 条转发" }
                }
                return
            }
            // 全部成功
            conn = .connected(since: Date())
            for r in outcome.opened {
                errors[r.local] = nil
                active.insert(r.local)
            }
        }
    }

    func closeAll() {
        for r in allRules where active.contains(r.local) { close(r) }
    }

    func openAll() {
        openGroup(allRules)
    }

    // 万能入口解析：3000 | 8080:80 | 3000 web | 3000 @web
    func parseQuick(_ s: String) -> (rule: Rule, group: String?)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: " ").map(String.init)
        let portToken = parts[0]
        let groupName = parts.count > 1 ? parts[1].replacingOccurrences(of: "@", with: "") : nil

        if portToken.contains(":") {
            let p = portToken.split(separator: ":").map(String.init)
            guard p.count == 2, let l = Int(p[0]), let r = Int(p[1]), isValid(l), isValid(r) else { return nil }
            return (Rule(local: l, remote: r), groupName)
        }
        guard let l = Int(portToken), isValid(l) else { return nil }
        return (Rule(local: l, remote: l), groupName)
    }

    private func isValid(_ p: Int) -> Bool { p > 0 && p < 65536 }

    func commitQuick() {
        guard let (rule, groupName) = parseQuick(quickInput) else {
            lastHint = "无法识别：\(quickInput)  ·  格式：3000 / 8080:80 / 3000 web"
            quickInput = ""
            return
        }
        if let g = groupName, let idx = config.groups.firstIndex(where: { $0.name == g }) {
            if !config.groups[idx].rules.contains(rule) { config.groups[idx].rules.append(rule) }
            open(rule)
        } else if groupName != nil {
            lastHint = "没有名为 \(groupName!) 的组"
            quickInput = ""
            return
        } else {
            if !adhoc.contains(rule) { adhoc.append(rule) }
            open(rule)
        }
        quickInput = ""
        save()
    }

    func addRule(_ r: Rule, to g: Group) {
        guard let idx = config.groups.firstIndex(where: { $0.name == g.name }) else { return }
        if !config.groups[idx].rules.contains(r) { config.groups[idx].rules.append(r) }
        save()
    }

    func removeRule(_ r: Rule, from g: Group) {
        guard let idx = config.groups.firstIndex(where: { $0.name == g.name }) else { return }
        config.groups[idx].rules.removeAll { $0 == r }
        if active.contains(r.local) { close(r) }
        save()
    }

    func removeAdhoc(_ r: Rule) {
        adhoc.removeAll { $0 == r }
        if active.contains(r.local) { close(r) }
    }

    func addGroup() {
        var n = "new"
        var i = 1
        while config.groups.contains(where: { $0.name == n }) { n = "new\(i)"; i += 1 }
        config.groups.append(Group(name: n))
        save()
    }

    func removeGroup(_ g: Group) {
        g.rules.forEach { if active.contains($0.local) { close($0) } }
        config.groups.removeAll { $0.name == g.name }
        save()
    }

    func openConfigFile() {
        let url = configURL
        if !FileManager.default.fileExists(atPath: url.path) { save() }
        NSWorkspace.shared.open(url)
    }

    var usageHint: String { "3000 · 8080:80 · 3000 web · 3000 @web" }
}

// MARK: - 视图

struct Chip: View {
    let rule: Rule
    let on: Bool
    let err: String?
    let action: () -> Void
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Button(action: action) {
                HStack(spacing: 4) {
                    Circle().fill(on ? Color.green : Color.clear)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().strokeBorder(on ? Color.clear : Color.secondary.opacity(0.5)))
                    Text(rule.label).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                    if let err {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help(err)
                    }
                }
            }
            .buttonStyle(.plain)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? Color.green.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(err != nil ? Color.orange.opacity(0.5)
                            : on ? Color.green.opacity(0.35) : Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 0.5, dash: on && err == nil ? [] : [2, 2]))
        )
    }
}

struct GroupRow: View {
    @ObservedObject var store: Store
    let group: Group
    let adhoc: Bool

    private var onCount: Int { group.rules.filter { store.active.contains($0.local) }.count }
    private var allOn: Bool { !group.rules.isEmpty && onCount == group.rules.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Button {
                    adhoc ? store.rules(in: group).forEach { store.toggle($0) } : store.toggleGroup(group)
                } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(allOn ? Color.green : Color.clear)
                            .frame(width: 9, height: 9)
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(allOn ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1))
                        Text(group.name).font(.system(size: 13, weight: .medium))
                        if !group.desc.isEmpty {
                            Text(group.desc).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Text("\(onCount)/\(group.rules.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if !group.rules.isEmpty {
                FlowRow(spacing: 4) {
                    ForEach(group.rules) { r in
                        Chip(rule: r, on: store.isOn(r), err: store.error(r),
                             action: { store.toggle(r) },
                             remove: adhoc ? { store.removeAdhoc(r) } : nil)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(onCount > 0 ? Color.secondary.opacity(0.08) : Color.clear)
        )
        .contextMenu {
            if !adhoc {
                Button("添加端口到本组…") { store.quickInput = ""; store.focusQuickSignal += 1 }
                Divider()
                Button("删除此组", role: .destructive) { store.removeGroup(group) }
            }
        }
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
        VStack(spacing: 0) {
            // 连接状态
            HStack(spacing: 7) {
                Circle().fill(Color(hex: store.dotColor) ?? .secondary).frame(width: 7, height: 7)
                Text(store.config.host.isEmpty ? "未选择主机" : store.config.host)
                    .font(.system(size: 13, weight: .medium))
                Text(store.connLabel).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Text("\(store.onCount)/\(store.totalCount)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.secondary.opacity(0.06))

            VStack(spacing: 0) {
                hostSection
                Divider().padding(.vertical, 8)
                groupSection
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let h = store.lastHint {
                Text(h).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.bottom, 4)
            }

            Divider()

            // 万能入口
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(.tertiary)
                    TextField("", text: $store.quickInput, prompt: Text(store.usageHint)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($inputFocused)
                        .onSubmit { store.commitQuick() }
                        .onChange(of: store.focusQuickSignal) { _, _ in inputFocused = true }
                    if !store.quickInput.isEmpty {
                        Image(systemName: "return").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))

                Text("格式：\(store.usageHint)")
                    .font(.system(size: 10)).foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3)
            }
            .padding(.horizontal, 10).padding(.top, 8)

            // 动作
            VStack(spacing: 1) {
                row("全部开启", "⇧⌘↑") { store.openAll() }
                row("全部关闭", "⇧⌘↓") { store.closeAll() }
                Divider().padding(.vertical, 3)
                row("重新载入配置", "") { store.reloadFromDisk() }
                Divider().padding(.vertical, 3)
                row("退出 pmap", "⌘Q") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .frame(width: 360)
        .onAppear { store.probeOnlineHosts() }
    }

    // 主机切换
    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.hostAliases.isEmpty {
                Text("~/.ssh/config 里没有可用的 Host 条目")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                FlowRow(spacing: 5) {
                    ForEach(store.hostAliases, id: \.self) { alias in
                        hostChip(alias, store: store)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("重连") { store.refreshConnection() }.buttonStyle(.plain)
                    .font(.system(size: 11))
                Text("·").foregroundStyle(.quaternary).font(.system(size: 11))
                Button("打开 config.json") { store.openConfigFile() }.buttonStyle(.plain)
                    .font(.system(size: 11))
                Spacer()
            }

            if let t = store.target {
                VStack(alignment: .leading, spacing: 3) {
                    info("地址", "\(t.hostname):\(t.port)")
                    info("用户", t.user)
                    if !t.proxyJump.isEmpty { info("跳板", t.proxyJump) }
                    if !t.identityFile.isEmpty { info("密钥", t.identityFile) }
                    info("状态", store.connLabel)
                    if !t.aliasDefined {
                        Text("别名未在 ~/.ssh/config 中定义，可能连不上")
                            .font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                Text("以上参数展开自 ~/.ssh/config，请到该文件修改")
                    .font(.system(size: 10)).foregroundStyle(.quaternary)
            } else if !store.config.host.isEmpty {
                Text("无法解析别名 \(store.config.host)")
                    .font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    // 组管理 + 组列表
    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("组").font(.system(size: 13, weight: .medium))
                Spacer()
                Button { store.addGroup() } label: {
                    Image(systemName: "plus").font(.system(size: 11))
                }.buttonStyle(.plain)
            }

            if store.config.groups.isEmpty && store.adhoc.isEmpty {
                Text("还没有组，点「+」或在下面输入 `3000 web` 建组")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }

            ForEach(store.config.groups) { g in
                GroupRow(store: store, group: g, adhoc: false)
            }
            if !store.adhoc.isEmpty {
                GroupRow(store: store,
                         group: Group(name: "临时", desc: "本次会话", rules: store.adhoc),
                         adhoc: true)
            }
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 40, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        }
    }

    /// 主机选择按钮。整块都是点击区，点击热区足够大。
    private func hostChip(_ alias: String, store: Store) -> some View {
        let on = store.config.host == alias
        let online = store.onlineHosts.contains(alias)
        return Button {
            store.selectHost(alias)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(on ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(alias)
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                if online && !on {
                    Text("在线").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(on ? Color.green.opacity(0.14) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(on ? Color.green.opacity(0.5) : Color.secondary.opacity(0.2),
                                  lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(on ? "当前主机" : "切换到 \(alias)")
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

struct GroupEdit: View {
    @ObservedObject var store: Store
    let group: Group

    private var idx: Int? { store.config.groups.firstIndex(where: { $0.name == group.name }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let i = idx {
                    TextField("组名", text: Binding(
                        get: { store.config.groups[i].name },
                        set: { store.config.groups[i].name = $0; store.save() }
                    ))
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .medium))

                    TextField("说明", text: Binding(
                        get: { store.config.groups[i].desc },
                        set: { store.config.groups[i].desc = $0; store.save() }
                    ))
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let i = idx { store.config.groups.remove(at: i); store.save() }
                } label: { Image(systemName: "trash").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.red.opacity(0.7))
            }
            if !group.rules.isEmpty {
                FlowRow(spacing: 4) {
                    ForEach(group.rules) { r in
                        Chip(rule: r, on: store.isOn(r), err: store.error(r),
                             action: { store.toggle(r) },
                             remove: { store.removeRule(r, from: group) })
                    }
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
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
