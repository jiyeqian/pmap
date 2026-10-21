// PortError.swift
// 端口/连接错误：结构化存储 + OpenSSH 原文归类 + 双语友好描述
//
// 为什么结构化：错误若以「渲染好的字符串」存储，切换语言后存量错误仍是旧语言；
// 这里以枚举保存语义，描述在渲染时按当前语言生成，切换即时生效。

import Foundation

enum PortError: Equatable, Sendable {
    /// 本地端口被占用（by = 占用进程名，nil 表示未知进程）
    case localPortBusy(port: Int, by: String?)
    /// 服务端禁止端口转发（sshd 关闭 AllowTcpForwarding）
    case forwardingNotAllowed
    /// 认证失败
    case authFailed
    /// 认证尝试次数过多
    case tooManyAuthFailures
    /// 连接被拒绝
    case connectionRefused
    /// 连接超时
    case timedOut
    /// SSH 主连接建立超时
    case sshConnectTimeout
    /// 找不到主机
    case hostNotFound
    /// 主机密钥校验失败
    case hostKeyRejected
    /// 握手 / 密钥协商失败
    case handshakeFailed
    /// 复用通道不可用（主连接未建立或已失效）
    case noControlConnection
    /// 未识别的 OpenSSH 原文（已截断）
    case ssh(raw: String)
    /// 未知错误
    case unknown

    /// 原始报错文本的最大长度（超长截断，避免 tooltip 过长）
    static let rawMaxLength = 60

    /// 把 OpenSSH / 系统原始报错归类为结构化错误（语言无关的纯字符串处理）
    /// 注意判断顺序：更具体的网络错误（拒绝 / 超时 / 找不到主机）要排在
    /// 「open failed」这类含糊短语之前，否则会被误判为「服务端禁止转发」。
    static func classify(_ raw: String, localPort: Int) -> PortError {
        let s = raw.lowercased()
        func has(_ keys: [String]) -> Bool { keys.contains { s.contains($0) } }

        // 1. 本地端口被占用
        if has(["address already in use", "cannot listen to port",
                "bind: ", "bind [", "bind:0", "address in use"]) {
            return .localPortBusy(port: localPort, by: nil)
        }
        // 2. 认证类
        if has(["too many authentication failures"]) {
            return .tooManyAuthFailures
        }
        if has(["host key verification failed"]) {
            return .hostKeyRejected
        }
        if has(["permission denied", "authentication failed", "auth failed",
                "no supported authentication", "publickey"]) {
            return .authFailed
        }
        // 3. 复用通道不可用（ssh -O forward 依赖主连接）
        if has(["control socket connect", "control socket", "mux_client_request_session"]) {
            return .noControlConnection
        }
        // 4. 网络类（必须早于 open failed 判定）
        if has(["connection refused"]) { return .connectionRefused }
        if has(["timed out", "timeout", "operation timed out"]) { return .timedOut }
        if has(["could not resolve hostname", "name or service not known",
                "no route to host", "host is unreachable", "nodename nor servname"]) {
            return .hostNotFound
        }
        // 5. 握手 / 协商失败
        if has(["kex_exchange_identification", "connection closed by remote host",
                "no matching", "handshake failed", "banner exchange failed"]) {
            return .handshakeFailed
        }
        // 6. 服务端禁止转发
        if has(["administratively prohibited", "forwarding not allowed",
                "not permitted", "channel_setup_fwd_listener",
                "remote port forwarding failed"]) {
            return .forwardingNotAllowed
        }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .unknown }

        return .ssh(raw: truncate(raw))
    }

    /// 截断过长原文，避免 tooltip 被单行文本撑爆
    static func truncate(_ raw: String) -> String {
        let oneLine = raw.split(separator: "\n").first.map(String.init) ?? raw
        let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= rawMaxLength { return trimmed }
        return String(trimmed.prefix(rawMaxLength)) + "…"
    }

    /// 双语友好描述（渲染时调用 → 切语言即时生效）
    func description(_ lang: Lang) -> String {
        switch self {
        case .localPortBusy(let port, let by):
            let name = (by?.isEmpty == false) ? by! : L10n.text(.errBusyOther, lang)
            return L10n.text(.errPortBusy, lang, port, name)
        case .forwardingNotAllowed:
            return L10n.text(.errForwardNotAllowed, lang)
        case .authFailed:
            return L10n.text(.errAuthFailed, lang)
        case .tooManyAuthFailures:
            return L10n.text(.errTooManyAuth, lang)
        case .connectionRefused:
            return L10n.text(.errConnRefused, lang)
        case .timedOut:
            return L10n.text(.errTimeout, lang)
        case .sshConnectTimeout:
            return L10n.text(.errSSHTimeout, lang)
        case .handshakeFailed:
            return L10n.text(.errHandshakeFailed, lang)
        case .noControlConnection:
            return L10n.text(.errNoControlConnection, lang)
        case .hostNotFound:
            return L10n.text(.errHostNotFound, lang)
        case .hostKeyRejected:
            return L10n.text(.errHostKeyRejected, lang)
        case .ssh(let raw):
            return L10n.text(.errRaw, lang, raw)
        case .unknown:
            return L10n.text(.errUnknown, lang)
        }
    }
}
