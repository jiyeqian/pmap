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

    /// 统一按 port:port 显示（即使 local==remote）
    var label: String { "\(local):\(remote)" }
}

struct Group: Codable, Identifiable {
    var name: String
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

    /// 启动时：若有选中主机（config.host 非空且可见），自动连接
    func autoConnectIfNeeded() {
        let h = config.host
        guard !h.isEmpty, visibleHosts.contains(h), hostState[h] == .off else { return }
        connectHost(h)
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

    // MARK: 主机连接（下拉选中即连接）

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

    /// 下拉选中主机：选中即连接（已连接则保持）
    func selectHost(_ alias: String) {
        if activeHost == alias && hostState[alias] == .on { return }
        // 其余主机全部断开
        for h in hostState.keys where h != alias && hostState[h] != .off {
            hostState[h] = .off
        }
        if let cur = activeHost { disconnectHost(cur) }
        connectHost(alias)
    }

    /// 主机状态文字（下拉框标题）
    func hostStatusText(_ alias: String) -> String {
        switch hostState[alias] ?? .off {
        case .off: return "断开"
        case .connecting: return "连接中…"
        case .on: return "连通"
        case .failed: return "故障"
        }
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

    // 万能入口解析：port 或 port:port（@组名 已不再分组，忽略 @ 后内容）
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

    static var usageHint: String { "格式：port/port:port@组名" }

    func commitQuick() {
        guard let (rule, _) = parseQuick(quickInput) else {
            // 不弹出任何文字破坏面板：清空输入，输入框内红色高亮格式提示
            quickInput = ""
            inputInvalid = true
            return
        }
        // 不再分组：端口统一落 adhoc（扁平列表），按 local 去重
        let samePort = { (r: Rule) in r.local == rule.local }
        if !adhoc.contains(where: samePort) {
            adhoc.append(rule)
        }
        quickInput = ""
        inputInvalid = false
        save()
        // 已连接主机则自动点亮（open 内部会在无连接时保持灰）
        if !active.contains(rule.local) { open(rule) }
    }

    /// 删除端口：从组或临时列表中移除（扁平视图统一入口）
    func removeRuleAnywhere(_ r: Rule) {
        for i in config.groups.indices {
            config.groups[i].rules.removeAll { $0.local == r.local }
        }
        config.groups.removeAll { $0.rules.isEmpty }
        adhoc.removeAll { $0.local == r.local }
        if active.contains(r.local) { close(r) }
        save()
    }
}

// MARK: - 视图

/// 端口行：小圆点（三色状态）+ 端口文字（单色）；单击开关，双击删除
struct Chip: View {
    let rule: Rule
    let on: Bool
    let err: String?
    let action: () -> Void
    let remove: () -> Void

    private var dotColor: Color {
        if err != nil { return .red }
        return on ? .green : Color.secondary.opacity(0.5)
    }
    private var hint: String {
        if let e = err { return e }
        return on ? "单击关闭 · 双击删除" : "单击开启 · 双击删除"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(rule.label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { remove() }
        .onTapGesture(count: 1) { action() }
        .help(hint)
    }
}

struct MenuPanel: View {
    @ObservedObject var store: Store
    @FocusState var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 第一项：主机下拉菜单（选中即连接）
            hostMenu
                .padding(.horizontal, 10).padding(.vertical, 8)

            // 端口（单列；小圆点三色 + 单色文字；单击开关，双击删除）
            if store.allRules.isEmpty {
                Text("在下方输入端口添加")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.allRules) { r in
                        Chip(rule: r, on: store.isOn(r), err: store.error(r),
                             action: { store.toggle(r) },
                             remove: { store.removeRuleAnywhere(r) })
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 2)
            }

            // 万能输入框（唯一入口；格式错误仅文字红显）
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
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .onAppear { inputFocused = true }

            // 最后一项：退出
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 2).padding(.bottom, 4)
        }
        .frame(width: 220)
    }

    /// 主机下拉框：标题显示当前状态文字（断开/连接中…/连通/故障），选中即连接
    private var hostMenu: some View {
        Menu {
            ForEach(store.visibleHosts, id: \.self) { alias in
                Button {
                    store.selectHost(alias)
                } label: {
                    if store.activeHost == alias {
                        Label(alias, systemImage: "checkmark")
                    } else {
                        Text(alias)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(store.activeHost ?? "选择主机")
                    .font(.system(size: 12))
                    .foregroundStyle(hostStatusColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(store.activeHost.map { store.hostStatusText($0) } ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(hostStatusColor)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity)
    }

    private var hostStatusColor: Color {
        guard let h = store.activeHost else { return .secondary }
        switch store.hostState[h] ?? .off {
        case .off: return .secondary
        case .connecting: return .secondary
        case .on: return .green
        case .failed: return .red
        }
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
        let vc = NSHostingController(rootView: MenuPanel(store: store).frame(width: 220))
        vc.sizingOptions = .preferredContentSize   // 自适应内容高度，避免截断
        popover.contentSize = NSSize(width: 220, height: 640)
        popover.contentViewController = vc

        // 启动时：若有选中主机，自动连接
        store.autoConnectIfNeeded()
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
