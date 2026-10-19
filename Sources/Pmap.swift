// Pmap.swift
// 菜单栏端口映射工具 —— 复用 SSH ControlMaster 连接的端口转发开关
//
// 构建: ./build.sh
// 运行: ./pmap.app

import SwiftUI
import AppKit
import Combine
import UserNotifications

// MARK: - 系统通知

enum Notifier {
    /// 申请通知授权（首次启动时调用）
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 发送一条系统通知
    static func post(title: String, body: String, sound: UNNotificationSound = .default) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
    @Published var inputInvalid: String? = nil          // 万能输入错误提示（非空则输入框红显）

    @Published var hostAliases: [String] = []
    private var heartbeatTask: Task<Void, Never>?       // 断线检测心跳

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
        adhoc = config.adhoc ?? []
        active = Set(config.active ?? [])     // 恢复端口开启状态
        refreshHosts()
    }

    func save() {
        config.adhoc = adhoc                  // 端口持久化
        config.active = Array(active).sorted() // 端口状态持久化
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

    /// 启动时：若有选中主机（config.host 非空且可见），自动连接并恢复端口转发
    func autoConnectIfNeeded() {
        let h = config.host
        guard !h.isEmpty, visibleHosts.contains(h), hostState[h] == .off else { return }
        connectHost(h, restorePorts: true)
    }

    /// 退出前：断开全部端口映射 + 断开主机
    func shutdownAll() {
        stopHeartbeat()
        let ports = allRules.filter { active.contains($0.local) }
        let host = connHost ?? config.host
        active.removeAll()
        errors.removeAll()
        for h in hostState.keys { hostState[h] = .off }
        activeHost = nil
        if !host.isEmpty {
            Task.detached {
                for r in ports { _ = Tunnel.cancel(host: host, r) }
                Tunnel.shutdown(host: host)
            }
        }
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

    private func connectHost(_ alias: String, restorePorts: Bool = false) {
        stopHeartbeat()
        hostState[alias] = .connecting
        activeHost = alias
        config.host = alias
        save()
        // 记录需要恢复的端口（连接成功后再逐个重建转发）
        let toRestore = restorePorts ? allRules.filter { active.contains($0.local) } : []
        Task {
            let e = await Task.detached { Tunnel.ensureConnection(host: alias) }.value
            if e != nil {
                hostState[alias] = .failed
                return
            }
            hostState[alias] = .on
            // 恢复退出前已开启的端口转发
            for r in toRestore {
                let fwdErr = await Task.detached { Tunnel.forward(host: alias, r) }.value
                if fwdErr != nil { errors[r.local] = fwdErr } else { errors[r.local] = nil }
            }
            self.startHeartbeat(host: alias)
        }
    }

    private func disconnectHost(_ alias: String) {
        stopHeartbeat()
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

    // MARK: 断线自动恢复

    /// 启动心跳：每 30 秒检测一次连接是否存活，断开则自动重连并恢复端口
    private func startHeartbeat(host: String) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var wasDown = false   // 上一次检测是否为「已断开」，避免重复发通知
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                guard let self else { break }
                // 后台检测连接是否存活
                let alive = await Task.detached { Tunnel.check(host: host) }.value
                if !alive {
                    // 首次发现断线：发通知
                    if !wasDown {
                        Notifier.post(title: "pmap 连接断开",
                                      body: "主机 \(host) 已断开，正在自动重连…")
                        wasDown = true
                    }
                    // 断线：保留 active（记住哪些端口该开），自动重连并恢复
                    self.hostState[host] = .connecting
                    let toRestore = self.allRules.filter { self.active.contains($0.local) }
                    let err = await Task.detached { Tunnel.ensureConnection(host: host) }.value
                    if err != nil {
                        self.hostState[host] = .failed
                        continue
                    }
                    self.hostState[host] = .on
                    for r in toRestore {
                        let fwdErr = await Task.detached { Tunnel.forward(host: host, r) }.value
                        if fwdErr != nil { self.errors[r.local] = fwdErr } else { self.errors[r.local] = nil }
                    }
                    // 重连成功：发通知
                    Notifier.post(title: "pmap 已重连",
                                  body: "主机 \(host) 连接已恢复，\(toRestore.count) 个端口转发已重建")
                    wasDown = false
                } else {
                    wasDown = false
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
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
        // 已开启则幂等跳过（避免把 ssh 自己占用的端口误判为「被占用」）
        if active.contains(r.local) { return }
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

    func commitQuick() {
        guard let (rule, _) = parseQuickInput(quickInput) else {
            // 格式错误：清空输入，输入框内红色高亮格式提示
            quickInput = ""
            inputInvalid = usageHint
            return
        }
        // 本地端口冲突检查：local 不能重复（远端可重复）
        let samePort = { (r: Rule) in r.local == rule.local }
        if adhoc.contains(where: samePort) || config.groups.flatMap(\.rules).contains(where: samePort) {
            quickInput = ""
            inputInvalid = "本地端口已映射"
            return
        }
        adhoc.append(rule)
        quickInput = ""
        inputInvalid = nil
        save()
        // 已连接主机则自动点亮（open 内部会在无连接时保持灰）
        open(rule)
    }

    /// 删除端口：从列表移除，并停掉映射服务（若该端口正在运行）
    func removeRuleAnywhere(_ r: Rule) {
        for i in config.groups.indices {
            config.groups[i].rules.removeAll { $0.local == r.local }
        }
        config.groups.removeAll { $0.rules.isEmpty }
        adhoc.removeAll { $0.local == r.local }
        // 若端口正在运行，先停掉映射（用当前活动主机，若已断开则用 config.host 兜底）
        if active.contains(r.local) {
            let host = connHost ?? config.host
            if !host.isEmpty {
                Task.detached { _ = Tunnel.cancel(host: host, r) }
            }
            active.remove(r.local)
            errors[r.local] = nil
        }
        save()
    }
}

// MARK: - 视图

/// 行悬停高亮（参考系统菜单：鼠标移到该项右高亮）
struct RowHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Color.primary.opacity(0.09) : Color.clear))
            .onHover { hovering = $0 }
    }
}

extension View {
    func rowHover() -> some View { modifier(RowHover()) }
}

/// 端口行：小圆点（三色状态）+ 端口文字（单色）+ 右侧删除图标
struct Chip: View {
    let rule: Rule
    let on: Bool
    let err: String?
    let action: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    private var dotColor: Color {
        if err != nil { return .red }
        return on ? .green : Color.secondary.opacity(0.5)
    }
    private var hint: String {
        if let e = err { return e }
        return on ? "单击关闭" : "单击开启"
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(rule.label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)   // 端口号优先完整显示，空间不足时截断备注
                .onTapGesture(count: 1) { action() }
            if let note = rule.note?.trimmingCharacters(in: .whitespaces), !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // 删除图标（单击删除）
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            .help("删除端口")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovering ? Color.primary.opacity(0.09) : Color.clear))
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .help(hint)
    }
}

struct MenuPanel: View {
    @ObservedObject var store: Store
    @FocusState var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 第一项：主机下拉菜单（选中即连接）；顶部留白更大
            hostMenu
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            // 端口（单列；小圆点三色 + 单色文字；单击开关，双击删除）
            if store.allRules.isEmpty {
                Text("在下方输入端口添加")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.allRules) { r in
                        Chip(rule: r, on: store.isOn(r), err: store.error(r),
                             action: { store.toggle(r) },
                             remove: { store.removeRuleAnywhere(r) })
                    }
                }
                .padding(.vertical, 4)
            }

            // 万能输入框（唯一入口；格式/冲突错误仅文字红显）
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.tertiary)
                TextField("", text: $store.quickInput,
                          prompt: Text(store.inputInvalid ?? usageHint)
                              .font(.system(size: 11, design: .monospaced))
                              .foregroundColor(store.inputInvalid != nil ? .red : .secondary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(store.inputInvalid != nil ? Color.red : Color.primary)
                    .focused($inputFocused)
                    .onSubmit { store.commitQuick() }
                    .onChange(of: store.quickInput) { _, nv in
                        if !nv.isEmpty { store.inputInvalid = nil }
                    }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .onAppear { inputFocused = true }

            Divider()

            // 倒数第二项：pmap 版本（点击打开 GitHub）
            Button {
                if let url = URL(string: "https://github.com/jiyeqian/pmap") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack {
                    Text("pmap \(appVersion)")
                        .font(.system(size: 11))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rowHover()

            Divider()

            // 最后一项：退出；底部留白更大
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Text("Quit")
                        .font(.system(size: 11))
                    Spacer()
                    Text("⌘Q")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rowHover()
        }
        .frame(width: 180)
    }

    private var appVersion: String {
        // 优先读 Info.plist；读不到则用编译期注入的 __PMAP_VERSION__ 兜底
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "__PMAP_VERSION__"
    }

    /// 主机下拉框：标题显示当前状态文字（断开/连接中…/连通/故障），选中即连接
    private var hostMenu: some View {
        Menu {
            // 未读到 ~/.ssh/config 或无可用主机时给出提示
            if store.visibleHosts.isEmpty {
                Text("未在 ~/.ssh/config 中找到可用主机")
            }
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
                Text(store.visibleHosts.isEmpty ? "无可用主机" : (store.activeHost ?? "选择主机"))
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

/// 万能输入框占位文字探针：与真实输入行同布局、同样式，但用纯 Text 代替
/// TextField（后者无法被 ImageRenderer 渲染），用于目检占位文字是否完整显示
struct PromptProbe: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(usageHint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 180)
    }
}

extension Store {
    static var shared: Store?
}

/// 无边框面板（可成为 key window，支持输入框聚焦）
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: PanelWindow?
    private var countObserver: AnyCancellable?
    private var appearanceObserver: NSKeyValueObservation?
    private var eventMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let store = Store.shared else { return }

        // 申请系统通知授权（断线/重连提醒）
        Notifier.requestAuthorization()

        // 菜单栏图标 + 转发计数
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let btn = item.button {
            btn.action = #selector(togglePanel(_:))
            btn.target = self
        }
        refreshStatusIcon()

        // 状态变化（转发计数标题 + 图标染色）：合并监听所有相关来源
        let any = store.$active.map { _ in () }.eraseToAnyPublisher()
        let cfg = store.$config.map { _ in () }.eraseToAnyPublisher()
        let adh = store.$adhoc.map { _ in () }.eraseToAnyPublisher()
        let hs = store.$hostState.map { _ in () }.eraseToAnyPublisher()
        let err = store.$errors.map { _ in () }.eraseToAnyPublisher()
        let ah = store.$activeHost.map { _ in () }.eraseToAnyPublisher()
        countObserver = Publishers.MergeMany(any, cfg, adh, hs, err, ah)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatusIcon()
            }

        // 系统深浅色外观切换时刷新前景色（状态栏非 template，需手动适配）
        // AppKit 无 appearance 变化通知，官方推荐 KVO 观察 NSApplication.effectiveAppearance
        appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshStatusIcon()
            }
        }

        // 无箭头自绘面板（NSPopover 的箭头去不掉，改用无边框 NSPanel）
        let p = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: MenuPanel(store: store).frame(width: 180))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        p.contentView = content
        panel = p

        // 点击面板外自动关闭（模拟菜单行为）
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, let panel = self.panel, panel.isVisible else { return e }
            let loc = NSEvent.mouseLocation
            // 点在状态栏图标上：只关面板（吞掉事件，避免关闭后又立即打开）
            if let iconWin = self.statusItem?.button?.window, iconWin.frame.contains(loc) {
                self.closePanel()
                return nil
            }
            if !panel.frame.contains(loc) { self.closePanel() }
            return e
        }
        eventMonitors = [globalMonitor, localMonitor].compactMap { $0 }

        // 启动时：若有选中主机，自动连接
        store.autoConnectIfNeeded()
    }

    /// 刷新状态栏图标：动态染色（前景色随深浅色、圆点随状态）
    private func refreshStatusIcon() {
        guard let store = Store.shared, let btn = statusItem?.button else { return }

        // 前景色（圆环/竖笔）：深色菜单栏用白、浅色用黑
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ringColor: NSColor = isDark ? .white : .black

        // 圆点聚合色：红（故障）> 绿（主机连通）> 灰（空闲）
        let dot: NSColor
        if let host = store.activeHost, store.hostState[host] == .failed {
            dot = PmapColors.red
        } else if !store.errors.isEmpty {
            dot = PmapColors.red
        } else if let host = store.activeHost, store.hostState[host] == .on {
            dot = PmapColors.green
        } else {
            dot = PmapColors.idleGray
        }

        btn.image = pmapStatusBarIcon(ringColor: ringColor, dotColor: dot)
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let panel, let btn = statusItem?.button, let iconWin = btn.window else { return }
        if panel.isVisible {
            closePanel()
            return
        }
        // 尺寸随内容自适应
        let fit = panel.contentView?.fittingSize ?? NSSize(width: 180, height: 200)
        var frame = panel.frame
        frame.size = NSSize(width: 180, height: max(fit.height, 100))
        // 左边缘对齐状态栏图标左边缘；面板顶部贴住菜单栏下方
        frame.origin.x = iconWin.frame.minX
        let screen = iconWin.screen ?? NSScreen.main!
        frame.origin.y = screen.visibleFrame.maxY - frame.height - 5
        // 防止越出屏幕右缘
        if frame.maxX > screen.visibleFrame.maxX {
            frame.origin.x = screen.visibleFrame.maxX - frame.width
        }
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePanel() {
        panel?.orderOut(nil)
        Store.shared?.save()
    }

    /// 退出前：断开全部映射并保存状态（端口开启状态已先保存，重启可恢复）
    func applicationWillTerminate(_ notification: Notification) {
        guard let store = Store.shared else { return }
        store.save()          // 先保存端口开启状态，便于重启恢复
        store.shutdownAll()   // 再断开全部映射与主机连接
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
            // 附：占位文字探针。ImageRenderer 渲染不了 TextField（输出占位符），
            // 用与 prompt 完全相同的字体/颜色/lineLimit/minimumScaleFactor 和
            // 相同的行布局渲染一份纯 Text 替身，用于跨 SDK 目检占位是否被截断。
            Snapshot.write(PromptProbe(), to: out + "-prompt.png")
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
