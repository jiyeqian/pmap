// Parsing.swift
// 万能输入框解析（纯函数，无状态依赖，便于单元测试）

import Foundation

// MARK: - 输入解析

/// 端口合法范围：> 0 且 < 65536
func isValidPort(_ p: Int) -> Bool { p > 0 && p < 65536 }

/// 万能输入框占位提示
let usageHint: String = "port/port:port"

/// 万能入口解析：port 或 port:port（@组名 已不再分组，忽略 @ 后内容）
/// - `#` 后缀为端口备注（隐藏高级功能，如 `5432:5432#数据库`）
/// 返回 (规则, 组名)，组名恒为 nil（历史遗留字段）
func parseQuickInput(_ s: String) -> (rule: Rule, group: String?)? {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return nil }
    var portPart = t
    var group: String? = nil
    if let at = t.firstIndex(of: "@") {
        portPart = String(t[..<at]).trimmingCharacters(in: .whitespaces)
        let g = String(t[t.index(after: at)...]).trimmingCharacters(in: .whitespaces)
        group = g.isEmpty ? nil : g
    }
    // 隐藏高级功能：`#` 后缀为端口备注（如 5432:5432#数据库），不在输入框提示
    var note: String? = nil
    if let hash = portPart.firstIndex(of: "#") {
        let n = String(portPart[portPart.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
        note = n.isEmpty ? nil : n
        portPart = String(portPart[..<hash]).trimmingCharacters(in: .whitespaces)
    }
    guard !portPart.isEmpty, !portPart.contains(" ") else { return nil }
    if portPart.contains(":") {
        let p = portPart.split(separator: ":").map(String.init)
        guard p.count == 2, let l = Int(p[0]), let r = Int(p[1]), isValidPort(l), isValidPort(r) else { return nil }
        return (Rule(local: l, remote: r, note: note), group)
    }
    guard let l = Int(portPart), isValidPort(l) else { return nil }
    return (Rule(local: l, remote: l, note: note), group)
}
