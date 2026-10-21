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
        .notifyReconnectedBody: "主机 {0} 连接已恢复，{1} 个端口转发已重建",
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
        .errHostKeyRejected: "主机密钥校验失败",
        .errHandshakeFailed: "SSH 握手失败",
        .errNoControlConnection: "SSH 连接不可用",
        .errRaw: "错误：{0}",
    ]

    private static let en: [Key: String] = [
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
        .notifyReconnectedBody: "Host {0} restored; {1} port forward(s) rebuilt",
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
        .errHostKeyRejected: "Host key verification failed",
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
