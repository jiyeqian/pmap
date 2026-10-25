// I18n.swift
// 中英文文案查表（自建轻量本地化，不依赖 .strings / String Catalog）
//
// 设计要点：
// 1. 单一来源：所有界面文案集中在此表，避免散落在视图与逻辑层；
// 2. 缺词回落：英文表缺词时回落到中文，避免出现空白文案；
// 3. 语言无关数据：错误等以结构化枚举存储，渲染时才查表翻译。

import Foundation

// MARK: - 语言

/// 界面语言。zh = 中文，en = English。
enum Lang: String, Codable, CaseIterable {
    case zh
    case en

    /// 首次启动的默认语言：系统首选语言以 zh 开头 → 中文，否则英文
    static var system: Lang {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? .zh : .en
    }

    /// 切换按钮上显示的语言标签（语言自身的名字，不翻译）
    var tag: String { L10n.text(self == .zh ? .langTagZh : .langTagEn, .zh) }

    /// 另一种语言（供「点击即切换」用）
    var other: Lang { self == .zh ? .en : .zh }
}

// MARK: - 文案表

enum L10n {
    /// 全部文案键。`CaseIterable` 用于单测校验「每个键都翻译齐了」。
    enum Key: String, CaseIterable {

        case inputBadFormat
        case importLegacy
        case importTitle
        case importBody
        case importConfirm
        case importFailed
        case resumeSavedSession
        case authorizeSSHDirectory
        case allowAccess
        case chooseSSHDirectoryOnly
        case missingConfigHosts
        case unreadableConfig
        case missingKnownHosts
        case unreadableKnownHosts
        case allowExternalConfig
        case allowExternalKnownHosts
        case terminalCommandCopied
        case done
        case chooseConfig
        case options
        case about
        case help
        case authorize
        case configNeedsAccess
        case configMissing
        case configUnreadable
        case resetAccess
        case resetTitle
        case resetBody
        case resetConfirm
        case connectConfirm
        case helpBody
        case noHostsFound
        case copySSHCommand

        case connectionLost
        case settings
        case disconnect
        case refreshHosts
        case setupNeeded
        case setupTitle
        case setupGuide
        case configTrust
        case configTrusted
        case configTrustBody
        case confirm
        case cancelAction
        case selectSSHFolder
        case grantResources
        case disconnectBeforeAccess
        case accessIssue
        case storageIssue
        case restoreOnLaunch
        case autoReconnect
        case notificationsSetting
        case behavior
        case privacy
        case runtimeInformation
        case closeInformation
        case copyDiagnostics
        case privacyText
        case revokeAccess
        case forwardStatus
        case portStopped
        case portStarting
        case portRetrying
        case portInput
        case prepareTerminal
        case settingsHint
        case closePanel

        // 主机状态
        case hostOff
        case hostConnecting
        case hostOn
        case hostFailed

        // 面板控件
        case emptyPorts
        case inputDuplicated
        case clickToStop
        case clickToStart
        case deletePort
        case noHostsInConfig
        case selectHost
        case noHosts
        case openHomepage
        case quit
        case quitHelp

        // 语言切换
        case langTagZh
        case langTagEn
        case langSwitchToZh
        case langSwitchToEn

        // 系统通知
        case notifyDisconnected
        case notifyReconnectBody
        case notifyReconnected
        case notifyReconnectedSummary
        case notifyReconnectedBody
        case notifyPortsRestored
        case notifyPortsRestoredBody

        // 错误
        case errSSHTimeout
        case errUnknown
        case errPortBusy
        case errBusyOther
        case errForwardNotAllowed
        case errAuthFailed
        case errTooManyAuth
        case errConnRefused
        case errTimeout
        case errHostNotFound
        case errHostKeyRejected
        case errHandshakeFailed
        case errNoControlConnection
        case errRaw
    }

    private static let zh: [Key: String] = [
        .inputBadFormat: "格式：端口或端口:端口",
        .importLegacy: "导入旧版配置…",
        .importTitle: "导入旧版配置？",
        .importBody: "替换当前端口、语言和上次连接记录；保留当前文件授权，不删除原文件。",
        .importConfirm: "导入",
        .importFailed: "无法导入配置，请检查文件与端口格式。",
        .resumeSavedSession: "恢复上次连接…",
        .authorizeSSHDirectory: "授权 SSH 文件夹…",
        .allowAccess: "允许",
        .chooseSSHDirectoryOnly: "请选择 .ssh 文件夹。",
        .missingConfigHosts: "未找到 config 文件，没有可用主机。",
        .unreadableConfig: "无法读取 config 文件。",
        .missingKnownHosts: "未找到 known_hosts 文件，请在终端验证主机。",
        .unreadableKnownHosts: "无法读取 known_hosts 文件。",
        .allowExternalConfig: "请允许读取 SSH 配置文件 config。",
        .allowExternalKnownHosts: "请允许读取主机验证文件 known_hosts。",
        .terminalCommandCopied: "命令已复制，请在终端粘贴并回车。",
        .done: "好",
        .chooseConfig: "选择配置…",
        .options: "选项",
        .about: "关于 pmap",
        .help: "使用帮助",
        .authorize: "授权…",
        .configNeedsAccess: "需要授权：{0}",
        .configMissing: "找不到配置：{0}",
        .configUnreadable: "无法读取：{0}",
        .resetAccess: "撤销 SSH 文件夹授权",
        .resetTitle: "撤销 SSH 文件夹授权？",
        .resetBody: "将断开当前主机及端口转发，取消对 SSH 文件夹和关联文件的访问授权，并清除对 SSH 配置的信任。\n\n本操作不删除任何文件。",
        .resetConfirm: "撤销授权",
        .connectConfirm: "允许并连接",
        .helpBody: "授权 .ssh 文件夹，选择主机，输入端口或端口:端口；可加 #备注。请在终端验证主机并解锁密钥。",
        .noHostsFound: "config 文件中没有可用主机。",
        .copySSHCommand: "终端验证…",

        .connectionLost: "连接已断开；请查看主机状态。",
        .settings: "设置与帮助",
        .disconnect: "断开",
        .refreshHosts: "刷新主机列表",
        .setupNeeded: "首次使用：先在设置中授权 SSH 配置。",
        .setupTitle: "系统 SSH 配置",
        .setupGuide: "先在终端确认 ssh 主机别名 可以登录。pmap 使用系统 OpenSSH 和现有密钥，以非交互方式运行。首次主机指纹确认、密码及密钥解锁请在终端完成。",
        .configTrust: "允许执行 SSH 配置中的命令？",
        .configTrusted: "已授权使用 SSH 配置",
        .configTrustBody: "此配置包含可能在本机运行的命令。仅在你了解并信任其来源时允许。",
        .confirm: "确认授权",
        .cancelAction: "取消",
        .selectSSHFolder: "选择 .ssh 文件夹…",
        .grantResources: "授权文件…",
        .disconnectBeforeAccess: "修改文件授权前请先断开连接。",
        .accessIssue: "SSH 文件不可读或授权已失效，请在设置中重新授权。",
        .storageIssue: "配置读写失败",
        .restoreOnLaunch: "启动时恢复",
        .autoReconnect: "自动重连",
        .notificationsSetting: "连接状态通知",
        .behavior: "连接行为",
        .privacy: "隐私政策",
        .runtimeInformation: "运行信息",
        .closeInformation: "关闭",
        .copyDiagnostics: "复制脱敏诊断",
        .privacyText: "pmap 仅连接你所选 SSH 配置中的服务器，不复制私钥，不向开发者发送数据。授权记录和配置仅保存在本机。\n\n你可通过“撤销 SSH 文件夹授权”取消文件访问授权。",
        .revokeAccess: "撤销文件访问与配置信任",
        .forwardStatus: "转发已建立；未检测远端服务健康",
        .portStopped: "已停止",
        .portStarting: "处理中",
        .portRetrying: "失败或等待重试",
        .portInput: "本地端口或本地端口:远程端口",
        .prepareTerminal: "复制 SSH 命令并打开终端",
        .settingsHint: "支持 Host、Include、IdentityFile 和 ProxyJump；外部资源需要单独授权。ProxyCommand、Match exec、SSH Agent 和系统钥匙串兼容性取决于沙盒权限，不保证与终端完全一致。",
        .closePanel: "关闭面板",

        .hostOff: "断开",
        .hostConnecting: "连接中…",
        .hostOn: "连通",
        .hostFailed: "故障",

        .emptyPorts: "在下方输入端口添加",
        .inputDuplicated: "本地端口已映射",
        .clickToStop: "单击关闭",
        .clickToStart: "单击开启",
        .deletePort: "删除端口",
        .noHostsInConfig: "未在 ~/.ssh/config 中找到可用主机",
        .selectHost: "选择主机",
        .noHosts: "无可用主机",
        .openHomepage: "打开项目主页",
        .quit: "退出",
        .quitHelp: "退出 pmap",

        .langTagZh: "中",
        .langTagEn: "EN",
        .langSwitchToZh: "切换到 中文",
        .langSwitchToEn: "切换到 English",

        .notifyDisconnected: "pmap 连接断开",
        .notifyReconnectBody: "主机 {0} 已断开，正在自动重连…",
        .notifyReconnected: "pmap 已重连",
        .notifyReconnectedSummary: "连接已恢复，{0} 个端口待恢复",
        .notifyReconnectedBody: "主机 {0} 连接已恢复，{1} 个端口待恢复",
        .notifyPortsRestored: "pmap 端口已恢复",
        .notifyPortsRestoredBody: "{0} 个端口转发已自动恢复",

        .errSSHTimeout: "SSH 连接建立超时",
        .errUnknown: "未知错误",
        .errPortBusy: "本地 {0} 被 {1} 占用",
        .errBusyOther: "其他进程",
        .errForwardNotAllowed: "服务端禁止端口转发",
        .errAuthFailed: "认证失败",
        .errTooManyAuth: "认证尝试次数过多",
        .errConnRefused: "连接被拒绝",
        .errTimeout: "连接超时",
        .errHostNotFound: "找不到主机",
        .errHostKeyRejected: "主机密钥校验失败，请在终端验证主机。",
        .errHandshakeFailed: "SSH 握手失败",
        .errNoControlConnection: "SSH 连接不可用",
        .errRaw: "错误：{0}",
    ]

    private static let en: [Key: String] = [
        .inputBadFormat: "Use port or port:port",
        .importLegacy: "Import Previous Configuration…",
        .importTitle: "Import previous configuration?",
        .importBody: "Replace current ports, language, and saved session. Keep current file access. Original files are not deleted.",
        .importConfirm: "Import",
        .importFailed: "Cannot import configuration. Check the file and port format.",
        .resumeSavedSession: "Resume Saved Session…",
        .authorizeSSHDirectory: "Allow SSH Folder Access…",
        .allowAccess: "Allow",
        .chooseSSHDirectoryOnly: "Choose the .ssh folder.",
        .missingConfigHosts: "config file not found. No available hosts.",
        .unreadableConfig: "Cannot read config file.",
        .missingKnownHosts: "known_hosts file not found. Verify the host in Terminal.",
        .unreadableKnownHosts: "Cannot read known_hosts file.",
        .allowExternalConfig: "Allow reading the SSH configuration file config.",
        .allowExternalKnownHosts: "Allow reading the host verification file known_hosts.",
        .terminalCommandCopied: "Command copied. Paste it in Terminal and press Return.",
        .done: "OK",
        .chooseConfig: "Choose Configuration…",
        .options: "Options",
        .about: "About pmap",
        .help: "Help",
        .authorize: "Allow Access…",
        .configNeedsAccess: "Access needed: {0}",
        .configMissing: "Configuration missing: {0}",
        .configUnreadable: "Cannot read: {0}",
        .resetAccess: "Revoke SSH Folder Access",
        .resetTitle: "Revoke SSH folder access?",
        .resetBody: "Disconnect the current host and port forwards, revoke access to the SSH folder and associated files, and clear trust in the SSH configuration.\n\nNo files will be deleted.",
        .resetConfirm: "Revoke Access",
        .connectConfirm: "Allow and Connect",
        .helpBody: "Allow access to .ssh, select a host, then enter port or port:port; append #note for a label. Verify the host and unlock keys in Terminal.",
        .noHostsFound: "No available hosts in config file.",
        .copySSHCommand: "Verify in Terminal…",

        .connectionLost: "Connection lost. Check the host status.",
        .settings: "Settings & Help",
        .disconnect: "Disconnect",
        .refreshHosts: "Refresh Hosts",
        .setupNeeded: "First use: authorize your SSH configuration in Settings.",
        .setupTitle: "System SSH Configuration",
        .setupGuide: "First verify that ssh host-alias works in Terminal. pmap uses system OpenSSH and existing keys without an interactive terminal. Verify new host fingerprints and unlock keys in Terminal.",
        .configTrust: "Allow commands in the SSH configuration?",
        .configTrusted: "SSH configuration authorized",
        .configTrustBody: "This configuration contains commands that may run on your Mac. Allow only if you understand and trust their source.",
        .confirm: "Authorize",
        .cancelAction: "Cancel",
        .selectSSHFolder: "Select .ssh Folder…",
        .grantResources: "Authorize Files…",
        .disconnectBeforeAccess: "Disconnect before changing file access.",
        .accessIssue: "SSH files are unavailable or access has expired. Reauthorize in Settings.",
        .storageIssue: "Configuration error",
        .restoreOnLaunch: "Restore on Launch",
        .autoReconnect: "Auto Reconnect",
        .notificationsSetting: "Connection Notifications",
        .behavior: "Connection Behavior",
        .privacy: "Privacy Policy",
        .runtimeInformation: "Runtime Information",
        .closeInformation: "Close",
        .copyDiagnostics: "Copy Redacted Diagnostics",
        .privacyText: "pmap connects only to servers in your selected SSH configuration, does not copy private keys, and sends no data to the developer. Access records and configuration stay on your Mac.\n\nUse “Revoke SSH Folder Access” to revoke file access.",
        .revokeAccess: "Revoke File Access and Configuration Trust",
        .forwardStatus: "Forward established; remote service health is not checked",
        .portStopped: "Stopped",
        .portStarting: "Working",
        .portRetrying: "Failed or Waiting to Retry",
        .portInput: "Local Port or Local Port:Remote Port",
        .prepareTerminal: "Copy SSH Command and Open Terminal",
        .settingsHint: "Supports Host, Include, IdentityFile, and ProxyJump; external resources need separate authorization. ProxyCommand, Match exec, SSH Agent, and system Keychain compatibility depend on sandbox permissions and may differ from Terminal.",
        .closePanel: "Close Panel",

        .hostOff: "Off",
        .hostConnecting: "Connecting…",
        .hostOn: "On",
        .hostFailed: "Failed",

        .emptyPorts: "Type a port below",
        .inputDuplicated: "Local port already mapped",
        .clickToStop: "Click to stop",
        .clickToStart: "Click to start",
        .deletePort: "Delete port",
        .noHostsInConfig: "No hosts in ~/.ssh/config",
        .selectHost: "Select host",
        .noHosts: "No hosts",
        .openHomepage: "Open project homepage",
        .quit: "Quit",
        .quitHelp: "Quit pmap",

        .langTagZh: "中",
        .langTagEn: "EN",
        .langSwitchToZh: "Switch to 中文",
        .langSwitchToEn: "Switch to English",

        .notifyDisconnected: "pmap disconnected",
        .notifyReconnectBody: "Host {0} dropped; reconnecting…",
        .notifyReconnected: "pmap reconnected",
        .notifyReconnectedSummary: "Connection restored; {0} port forward(s) pending",
        .notifyReconnectedBody: "Host {0} restored; {1} port forward(s) pending",
        .notifyPortsRestored: "pmap ports restored",
        .notifyPortsRestoredBody: "{0} port forward(s) recovered automatically",

        .errSSHTimeout: "SSH connection timed out",
        .errUnknown: "Unknown error",
        .errPortBusy: "Local port {0} is in use by {1}",
        .errBusyOther: "another process",
        .errForwardNotAllowed: "Forwarding not allowed by server",
        .errAuthFailed: "Authentication failed",
        .errTooManyAuth: "Too many authentication failures",
        .errConnRefused: "Connection refused",
        .errTimeout: "Connection timed out",
        .errHostNotFound: "Host not found",
        .errHostKeyRejected: "Host key verification failed. Verify the host in Terminal.",
        .errHandshakeFailed: "SSH handshake failed",
        .errNoControlConnection: "SSH connection unavailable",
        .errRaw: "Error: {0}",
    ]

    /// 查表取文案。英文缺词时回落到中文，避免空白。
    /// 带参数时按 `{0}`、`{1}` 占位符顺序替换（中英模板参数顺序一致）。
    static func text(_ key: Key, _ lang: Lang, _ args: CVarArg...) -> String {
        let template = (lang == .en ? en[key] : nil) ?? zh[key] ?? key.rawValue
        guard !args.isEmpty else { return template }
        var out = template
        for (i, a) in args.enumerated() {
            out = out.replacingOccurrences(of: "{\(i)}", with: String(describing: a))
        }
        return out
    }

    /// 语言切换按钮的提示语（指向「另一种语言」）
    static func switchHint(_ lang: Lang) -> String {
        text(lang == .zh ? .langSwitchToEn : .langSwitchToZh, lang)
    }

    /// 该键在指定语言下是否已翻译（供单测校验无漏译）
    static func isTranslated(_ key: Key, _ lang: Lang) -> Bool {
        (lang == .zh ? zh[key] : en[key]).map { !$0.isEmpty } ?? false
    }

}
