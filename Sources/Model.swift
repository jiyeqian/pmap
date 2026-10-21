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

struct Rule: Codable, Hashable, Identifiable {
    var local: Int
    var remote: Int
    var note: String? = nil   // 端口备注（隐藏高级功能：`#备注` 后缀，可选，老配置无此键时解码为 nil）
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
    /// 端口列表（扁平，不再分组）——持久化端口
    var adhoc: [Rule]? = nil
    /// 已开启的本地端口（退出前保存，重启后恢复转发状态）
    var active: [Int]? = nil
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
