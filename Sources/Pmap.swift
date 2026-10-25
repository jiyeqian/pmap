// Pmap.swift
// 菜单栏端口映射工具 —— 复用 SSH ControlMaster 连接的端口转发开关
//
// 构建: ./build.sh
// 运行: ./pmap.app

import SwiftUI
import AppKit
import Combine
import UserNotifications

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

/// 轻量 hover 反馈：悬停时加深（用 opacity 而非 foregroundStyle，
/// 避免与子视图 Text 自身的 foregroundStyle 冲突）
struct HoverText: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .opacity(hovering ? 1.0 : 0.6)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverText() -> some View { modifier(HoverText()) }
}

/// 端口行：小圆点（三色状态）+ 端口文字（单色）+ 右侧删除图标
struct Chip: View {
    let rule: Rule
    let light: PortLight
    let desired: Bool
    let pending: Bool
    let err: PortError?
    let lang: Lang
    let action: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    /// 提示语：错误优先，其次是「单击开关」动作提示（二选一）
    private var hint: String {
        if let e = err { return e.description(lang) }
        return L10n.text(desired ? .clickToStop : .clickToStart, lang)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: light == .green ? "checkmark.circle.fill" : (light == .red ? "exclamationmark.circle.fill" : "minus.circle"))
                .foregroundStyle(light.color)
                .font(.system(size: 10))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Button(action: action) {
                HStack(spacing: 7) {
                    Text(rule.label)
                        .font(.system(size: 12, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                    if let note = rule.displayNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .accessibilityLabel(rule.accessibleLabel)
            .accessibilityValue(L10n.text(pending ? .portStarting : (light == .green ? .forwardStatus : (err != nil ? .portRetrying : .portStopped)), lang))
            .accessibilityHint(hint)
            .disabled(pending && !desired)
            .help(rule.accessibleLabel + " · " + hint)
            Spacer(minLength: 0)
            // 删除图标（单击删除）
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
            }
            .buttonStyle(.plain)
            .help(L10n.text(.deletePort, lang))
            .accessibilityLabel(L10n.text(.deletePort, lang) + " " + rule.label)
            .disabled(pending && !desired)
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
    @FocusState private var inputFocused: Bool

    var body: some View {
        SwiftUI.Group {
            if store.requiresSSHFolderAuthorization { authorizationPanel }
            else { workingPanel }
        }
        .frame(width: store.lang == .zh ? 220 : 240)
        .onAppear { store.refreshOnOpen() }
    }

    private var authorizationPanel: some View {
        VStack(spacing: 0) {
            Button(store.t(.authorizeSSHDirectory)) { PanelActions.chooseSSHDirectory(store) }
                .buttonStyle(.plain).font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Divider()
            HStack {
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).help(store.t(.quitHelp)).accessibilityLabel(store.t(.quit))
            }
            .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var workingPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            hostMenu
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 12)

            issueRow
            Divider()
            if store.allRules.isEmpty {
                Text(store.t(.emptyPorts))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.allRules) { rule in
                            Chip(rule: rule, light: store.portLight(rule), desired: store.desired.contains(rule.local),
                                 pending: store.pending.contains(rule.local), err: store.error(rule), lang: store.lang,
                                 action: { store.toggle(rule) }, remove: { store.removeRuleAnywhere(rule) })
                        }
                    }
                }
                .frame(height: min(CGFloat(store.allRules.count) * 28, 280))
                .padding(.vertical, 4)
            }
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.tertiary)
                TextField("", text: $store.quickInput,
                          prompt: Text(inputPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(store.inputInvalid != nil ? .red : .secondary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(store.inputInvalid != nil ? Color.red : Color.primary)
                    .focused($inputFocused)
                    .accessibilityLabel(store.t(.portInput))
                    .accessibilityValue(store.inputInvalid.map { $0.description(store.lang) } ?? store.quickInput)
                    .onSubmit { store.commitQuick() }
                    .onChange(of: store.quickInput) { _, value in if !value.isEmpty { store.inputInvalid = nil } }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            HStack(spacing: 8) {
                PanelAbout(store: store, version: appVersion)
                Spacer(minLength: 0)
                PanelOptions(store: store)
                Button { store.toggleLang() } label: {
                    Image(systemName: "globe").frame(width: 20, height: 20)
                }
                .help(L10n.switchHint(store.lang))
                .accessibilityLabel(L10n.switchHint(store.lang))
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 20, height: 20)
                }
                .help(store.t(.quitHelp))
                .accessibilityLabel(store.t(.quit))
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 10)
        }
        .onAppear { inputFocused = true }
    }

    @ViewBuilder private var issueRow: some View {
        if store.storageIssue {
            issueText(store.t(.storageIssue))
        } else if store.configIssue != nil {
            HStack(spacing: 6) {
                Text(store.configMessage ?? store.t(.unreadableConfig)).fixedSize(horizontal: false, vertical: true)
                if let request = store.requiredFileAccess {
                    Button(store.t(.authorize)) { PanelActions.authorize(store, target: request.target) }.buttonStyle(.plain)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 8)
        } else if let message = store.knownHostsMessage {
            HStack(spacing: 6) {
                Text(message).fixedSize(horizontal: false, vertical: true)
                if let request = store.requiredFileAccess {
                    Button(store.t(.authorize)) { PanelActions.authorize(store, target: request.target) }.buttonStyle(.plain)
                } else if !store.visibleHosts.isEmpty {
                    Button { PanelActions.verifyInTerminal(store) } label: { Image(systemName: "terminal") }
                        .help(store.t(.copySSHCommand)).accessibilityLabel(store.t(.copySSHCommand))
                }
            }
            .font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 8)
        } else if let error = store.hostError {
            HStack(spacing: 6) {
                Text(error.description(store.lang)).lineLimit(1).help(error.description(store.lang))
                Spacer(minLength: 0)
                if case .fileAccess(let path) = error {
                    Button(store.t(.authorize)) { PanelActions.authorize(store, target: URL(fileURLWithPath: path)) }
                } else {
                    Button { PanelActions.verifyInTerminal(store) } label: { Image(systemName: "terminal") }
                        .help(store.t(.copySSHCommand)).accessibilityLabel(store.t(.copySSHCommand))
                }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.red)
            .padding(.horizontal, 12).padding(.bottom, 8)
        } else if store.hasSavedSession {
            Button(store.t(.resumeSavedSession)) { PanelActions.connect(store.config.host, store: store) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 8)
        } else if store.visibleHosts.isEmpty, store.configIssue == nil {
            issueText(store.t(.noHostsFound))
        }
    }
    private func issueText(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .lineLimit(1).help(text).padding(.horizontal, 12).padding(.bottom, 8)
    }
    private var inputPrompt: String {
        store.inputInvalid?.description(store.lang) ?? usageHint
    }
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "__PMAP_VERSION__"
    }
    private var hostMenu: some View {
        Menu {
            if store.activeHost != nil {
                Button(store.t(.disconnect)) { store.disconnect() }
                Divider()
            }
            ForEach(store.visibleHosts, id: \.self) { host in
                Button { PanelActions.connect(host, store: store) } label: {
                    if store.activeHost == host { Label(host, systemImage: "checkmark") }
                    else { Text(host) }
                }
            }
        } label: {
            Text(store.activeHost.map { "\($0) · \(store.hostStatusText($0))" } ?? store.t(.selectHost))
                .font(.system(size: 12)).foregroundStyle(hostStatusColor)
                .lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var hostStatusColor: Color {
        guard let host = store.activeHost else { return .primary }
        switch store.hostState[host] ?? .off {
        case .on: return .green
        case .failed: return .red
        default: return .secondary
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
    var width: CGFloat = 180
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
        .frame(width: width)
    }
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
    private var langObserver: AnyCancellable?
    private var appearanceObserver: NSKeyValueObservation?
    private var eventMonitors: [Any] = []
    private var carouselTimer: Timer?        // 状态栏圆点轮播计时器
    private var carouselIndex: Int = 0
    private var carouselColors: [NSColor] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let store = Store.shared else { return }


        // 菜单栏图标 + 转发计数
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let btn = item.button {
            btn.setAccessibilityLabel("pmap")
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
        let access = store.$folderAuthorized.map { _ in () }.eraseToAnyPublisher()
        let configIssue = store.$configIssue.map { _ in () }.eraseToAnyPublisher()
        let knownHosts = store.$knownHostsIssue.map { _ in () }.eraseToAnyPublisher()
        countObserver = Publishers.MergeMany(any, cfg, adh, hs, err, ah, access, configIssue, knownHosts)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatusIcon()
                Task { @MainActor in self?.resizePanelToFit() }
            }

        // 语言切换：面板宽度按语言自适应（zh 180 / en 200），切换后即时调整
        langObserver = store.$lang
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.resizePanelToFit()
                }
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
        let content = NSHostingView(rootView: MenuPanel(store: store))
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        p.contentView = content
        panel = p
        if !CommandLine.arguments.contains("--panel") {
            PanelActions.restoreMainPanel = { [weak self] in
                DispatchQueue.main.async { self?.showPanel() }
            }
        }
        #if PMAP_ACCESS_FIXTURE
        if CommandLine.arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showPanel() }
        }
        #endif

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

    /// 刷新状态栏图标：动态染色 + 圆点轮播（前景色随深浅色，圆点按已开启端口状态色轮流显示）
    private func refreshStatusIcon() {
        guard let store = Store.shared else { return }

        // 前景色（圆环/竖笔）：深色菜单栏用白、浅色用黑
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ringColor: NSColor = isDark ? .white : .black

        // 轮播序列：全部端口（按 allRules 顺序）→ 端口灯规则色（与面板 Chip 同一函数）
        // 主机未连通时全部端口灯为灰 → 轮播序列全灰（纯端口中心，主机故障也灰）
        let newColors: [NSColor] = store.allRules.map { store.portLight($0).nsColor }

        // 序列变化则重置轮播索引（数量或内容不同）
        if newColors.count != carouselColors.count
            || zip(newColors, carouselColors).contains(where: { $0 != $1 }) {
            carouselIndex = 0
        }
        carouselColors = newColors

        // 空序列（无任何端口）→ 灰点，停表
        if newColors.isEmpty {
            carouselTimer?.invalidate()
            carouselTimer = nil
            applyStatusIcon(ringColor: ringColor, dotColor: PmapColors.idleGray)
            return
        }

        // 非空：立即显示当前时隙，并启动/复用 1.5s 轮播计时器
        applyStatusIcon(ringColor: ringColor, dotColor: newColors[carouselIndex])
        if carouselTimer == nil {
            carouselTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard !self.carouselColors.isEmpty else { return }
                    self.carouselIndex = (self.carouselIndex + 1) % self.carouselColors.count
                    self.applyStatusIcon(ringColor: self.currentRingColor(),
                                         dotColor: self.carouselColors[self.carouselIndex])
                }
            }
        }
    }

    /// 仅按给定颜色设置状态栏图标位图（不改变轮播状态）
    private func applyStatusIcon(ringColor: NSColor, dotColor: NSColor) {
        statusItem?.button?.image = pmapStatusBarIcon(ringColor: ringColor, dotColor: dotColor)
        if let store = Store.shared {
            statusItem?.button?.setAccessibilityValue("\(store.onCount) / \(store.allRules.count)")
        }
    }

    /// 当前深浅色对应的前景色
    private func currentRingColor() -> NSColor {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .white : .black
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let panel else { return }
        if panel.isVisible {
            closePanel()
            return
        }
        showPanel()
    }

    private func showPanel() {
        guard let panel, let btn = statusItem?.button, let iconWin = btn.window else { return }
        Store.shared?.refreshOnOpen()
        // 尺寸随内容自适应（宽度由语言决定：zh 180 / en 200）
        let fit = panel.contentView?.fittingSize ?? NSSize(width: 180, height: 200)
        var frame = panel.frame
        frame.size = NSSize(width: fit.width > 0 ? fit.width : 180, height: max(fit.height, 100))
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

    /// 语言切换后按新宽度即时调整面板（保持贴菜单栏、贴图标左边缘、不越出屏幕右缘）
    private func resizePanelToFit() {
        guard let panel, panel.isVisible,
              let btn = statusItem?.button, let iconWin = btn.window else { return }
        let fit = panel.contentView?.fittingSize ?? NSSize(width: 180, height: 200)
        var frame = panel.frame
        frame.size = NSSize(width: fit.width > 0 ? fit.width : frame.width, height: max(fit.height, 100))
        frame.origin.x = iconWin.frame.minX
        let screen = iconWin.screen ?? NSScreen.main!
        frame.origin.y = screen.visibleFrame.maxY - frame.height - 5
        if frame.maxX > screen.visibleFrame.maxX {
            frame.origin.x = screen.visibleFrame.maxX - frame.width
        }
        panel.setFrame(frame, display: true)
    }

    private func closePanel() {
        panel?.orderOut(nil)
        Store.shared?.save()
    }

    /// 退出前：同步释放端口与主连接，确保进程退出前端口真正释放
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        carouselTimer?.invalidate()
        guard let store = Store.shared else { return .terminateNow }
        store.save()          // 先保存端口开启状态，便于重启恢复
        Task {
            await store.shutdownAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 退出兜底：若 applicationShouldTerminate 未被触发（如系统强制退出），做最小清理
    func applicationWillTerminate(_ notification: Notification) {
        carouselTimer?.invalidate()
    }
}

@main
struct PmapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        #if PMAP_TEST_HARNESS
        if CommandLine.arguments.contains("--integration") {
            Task { exit(await IntegrationProbe.run()) }
            return
        }
        #endif
        let accessFixture: Store? = {
            #if PMAP_ACCESS_FIXTURE
            if let index = CommandLine.arguments.firstIndex(of: "--access-fixture"), index + 1 < CommandLine.arguments.count {
                let root = URL(fileURLWithPath: CommandLine.arguments[index + 1]).appendingPathComponent(".ssh")
                return Store(url: AppPaths.support.appendingPathComponent("folder-probe.json"), sshRoot: root)
            }
            #endif
            return nil
        }()
        if let accessFixture { Store.shared = accessFixture }
        else if CommandLine.arguments.contains("--preview") {
            let store = Store(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"), scanHosts: false)
            store.config.trustedConfig = true
            store.hostAliases = ["demo"]
            store.activeHost = "demo"
            store.hostState["demo"] = .on
            store.adhoc = (0..<(CommandLine.arguments.contains("--long-list") ? 40 : 3)).map {
                Rule(local: 8000 + $0, remote: 80 + $0, note: $0 == 0 ? "demo" : nil)
            }
            store.active = [8000]
            store.desired = [8000, 8001]
            store.errors[8001] = .localPortBusy(port: 8001, by: "demo")
            Store.shared = store
        } else {
            Store.shared = Store()
        }
        // 自检入口：`pmap.app/Contents/MacOS/pmap --list-hosts`
        if CommandLine.arguments.contains("--list-hosts") {
            let hosts = SSHConfig.listHosts()
            print("共 \(hosts.count) 台主机")
            for h in hosts { print("  " + h) }
            exit(0)
        }
        // 离屏渲染面板，用于开发期目检布局：--snapshot <输出路径> [--lang zh|en]
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
           i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            let store = Store()
            // 开发期可指定语言渲染（不写盘）
            if let li = CommandLine.arguments.firstIndex(of: "--lang"),
               li + 1 < CommandLine.arguments.count,
               let l = Lang(rawValue: CommandLine.arguments[li + 1]) {
                store.setLang(l, persist: false)
            }
            Snapshot.write(MenuPanel(store: store), to: out + ".png")
            // 附：占位文字探针。ImageRenderer 渲染不了 TextField（输出占位符），
            // 用与 prompt 完全相同的字体/颜色/lineLimit/minimumScaleFactor 和
            // 相同的行布局渲染一份纯 Text 替身，用于跨 SDK 目检占位是否被截断。
            Snapshot.write(PromptProbe(width: store.lang == .zh ? 180 : 200), to: out + "-prompt.png")
            exit(0)
        }
        // 真实渲染导出（非 ImageRenderer）：在深色窗口里用真实 AppKit 渲染面板，
        // 再抓取本进程窗口写成 PNG，用于像素级验证：--render <输出路径>
        if let i = CommandLine.arguments.firstIndex(of: "--render"),
           i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            // 开发期可指定语言渲染（不写盘）
            if let li = CommandLine.arguments.firstIndex(of: "--lang"),
               li + 1 < CommandLine.arguments.count,
               let l = Lang(rawValue: CommandLine.arguments[li + 1]) {
                Store.shared?.setLang(l, persist: false)
            }
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
                    let size = host.fittingSize
                    host.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
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
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}
