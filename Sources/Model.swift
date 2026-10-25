// Model.swift
// 纯数据模型：端口规则、分组、配置、SSH 目标、连接状态

import Foundation
import SwiftUI

// MARK: - 模型

/// 端口灯三态（面板端口灯与菜单灯轮播共用的单一规则来源）
/// 绿=转发中；红=转发失败（重试中）/ 本地端口被占用；灰=未开启 / 主机未连通
enum PortLight {
    case green, red, gray

    var color: Color {
        switch self {
        case .green: .green
        case .red: .red
        case .gray: Color(nsColor: .systemGray)
        }
    }

    var nsColor: NSColor {
        switch self {
        case .green: .systemGreen
        case .red: .systemRed
        case .gray: .systemGray
        }
    }
}

struct Rule: Codable, Hashable, Identifiable, Sendable {
    var local: Int
    var remote: Int
    var note: String? = nil   // 端口备注（隐藏高级功能：`#备注` 后缀，可选，老配置无此键时解码为 nil）
    var id: Int { local }

    /// 统一按 port:port 显示（即使 local==remote）
    var label: String { "\(local):\(remote)" }
    var displayNote: String? {
        guard let value = note?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    var accessibleLabel: String { displayNote.map { label + " · " + $0 } ?? label }
}

struct Group: Codable, Identifiable {
    var name: String
    var rules: [Rule] = []
    var id: String { name }
}

struct Config: Codable {
    var schemaVersion = 1
    var host = ""
    var groups: [Group] = []
    var adhoc: [Rule]? = nil
    /// Desired ports, including temporarily failed forwards.
    var active: [Int]? = nil
    var hiddenHosts: [String]? = nil
    var lang: String? = nil
    var restoreOnLaunch = true
    var autoReconnect = true
    var notifications = false
    var trustedConfig = false
    var bookmarks: [Data] = []
    var sshDirectory: String? = nil
    var sshConfigFile: String? = nil

    init() {}
    enum CodingKeys: String, CodingKey {
        case schemaVersion, host, groups, adhoc, active, hiddenHosts, lang
        case restoreOnLaunch, autoReconnect, notifications, trustedConfig, bookmarks, sshDirectory, sshConfigFile
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        groups = try c.decodeIfPresent([Group].self, forKey: .groups) ?? []
        adhoc = try c.decodeIfPresent([Rule].self, forKey: .adhoc)
        active = try c.decodeIfPresent([Int].self, forKey: .active)
        hiddenHosts = try c.decodeIfPresent([String].self, forKey: .hiddenHosts)
        lang = try c.decodeIfPresent(String.self, forKey: .lang)
        restoreOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .restoreOnLaunch) ?? true
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? false
        trustedConfig = try c.decodeIfPresent(Bool.self, forKey: .trustedConfig) ?? false
        bookmarks = try c.decodeIfPresent([Data].self, forKey: .bookmarks) ?? []
        sshDirectory = try c.decodeIfPresent(String.self, forKey: .sshDirectory)
        sshConfigFile = try c.decodeIfPresent(String.self, forKey: .sshConfigFile)
    }
}

/// 输入框错误类型（结构化存储，渲染时按语言翻译）
enum InputIssue: Equatable {
    func description(_ lang: Lang) -> String {
        L10n.text(self == .badFormat ? .inputBadFormat : .inputDuplicated, lang)
    }

    /// 格式不对（提示仍显示 port/port:port 格式说明）
    case badFormat
    /// 本地端口已被映射
    case duplicatedPort
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

enum HostConn: Equatable, Sendable {
    case off          // 灰：未连接
    case connecting   // 灰：连接中
    case on           // 绿：已连接
    case failed       // 红：连接失败
}
