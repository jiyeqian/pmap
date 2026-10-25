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
    case fileAccess(path: String)
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

        if has(["permission denied", "operation not permitted"]) {
            if let start = raw.range(of: "identity file ", options: .caseInsensitive), let end = raw.range(of: " not accessible", options: .caseInsensitive, range: start.upperBound..<raw.endIndex) {
                return .fileAccess(path: String(raw[start.upperBound..<end.lowerBound]))
            }
            if let start = raw.range(of: "Load key \"", options: .caseInsensitive), let end = raw.range(of: "\"", range: start.upperBound..<raw.endIndex) {
                return .fileAccess(path: String(raw[start.upperBound..<end.lowerBound]))
            }
        }
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
        case .fileAccess(let path):
            return L10n.text(.configNeedsAccess, lang, URL(fileURLWithPath: path).lastPathComponent)
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

extension PortError {
    /// Only fixed categories enter copied diagnostics; associated values may contain secrets.
    var diagnosticCode: String {
        switch self {
        case .localPortBusy: "local_port_busy"
        case .forwardingNotAllowed: "forwarding_not_allowed"
        case .authFailed: "authentication_failed"
        case .fileAccess: "file_access_denied"
        case .tooManyAuthFailures: "too_many_authentication_failures"
        case .connectionRefused: "connection_refused"
        case .timedOut: "connection_timed_out"
        case .sshConnectTimeout: "ssh_connect_timeout"
        case .hostNotFound: "host_unreachable_or_unresolved"
        case .hostKeyRejected: "host_key_rejected"
        case .handshakeFailed: "handshake_failed"
        case .noControlConnection: "control_connection_unavailable"
        case .ssh: "unclassified_ssh_error"
        case .unknown: "unknown_error"
        }
    }

    func recoverySteps(_ lang: Lang) -> String {
        func text(_ zh: String, _ en: String) -> String { lang == .zh ? zh : en }
        switch self {
        case .hostKeyRejected:
            return text("点击钥匙图标→终端验证…，粘贴已复制的命令执行。首次连接先通过可信渠道核对指纹；若提示指纹变化，先核实服务器身份再更新对应记录，不要删除整个 known_hosts 或关闭校验。若终端可登录，授权 SSH 配置实际使用的 known_hosts 文件（含外部链接目标），再重新选择原主机。", "Use the key menu → Verify in Terminal, paste and run the copied command. Verify new fingerprints through a trusted channel. If a key changed, verify the server before updating its entry; do not delete all known_hosts or disable checking. If Terminal connects, authorize the actual known_hosts file used by SSH (including external symlink targets), then reselect the host.")
        case .fileAccess:
            return text("点击错误旁的授权入口，选择报错的实际文件或符号链接目标；授权后重新选择原主机。", "Use Allow Access beside the error to select the actual file or symlink target, then reselect the host.")
        case .authFailed, .tooManyAuthFailures:
            return text("用钥匙菜单的终端验证确认登录和密钥解锁；核对 User、IdentityFile，密钥过多时配置 IdentitiesOnly yes。沙盒中授权实际密钥文件；Agent/钥匙串可能受限。处理后重新选择原主机。", "Verify login and unlock keys in Terminal. Check User and IdentityFile; use IdentitiesOnly yes when too many keys are offered. Authorize key files in the sandbox; Agent/Keychain access may be restricted. Then reselect the host.")
        case .localPortBusy:
            return text("在本机关闭占用该端口的程序，或删除失败规则并改用其他本地端口。自动重连开启时会重试；也可点击失败端口先停止、再开启。", "Stop the local program using the port, or replace the failed rule with a different local port. Auto Reconnect retries automatically; alternatively stop and restart the failed port.")
        case .forwardingNotAllowed:
            return text("请服务器管理员核查 AllowTcpForwarding、PermitOpen 和密钥的转发限制；允许后将失败端口先停止、再开启。", "Ask the server administrator to check AllowTcpForwarding, PermitOpen, and key restrictions. Once allowed, stop and restart the failed port.")
        case .connectionRefused, .timedOut, .sshConnectTimeout, .hostNotFound:
            return text("核对主机地址、SSH 端口、网络/VPN及服务器 SSH 服务；用终端验证确认可达。开启自动重连可等待恢复，也可重新选择原主机。", "Check the host address, SSH port, network/VPN, and server SSH service; verify reachability in Terminal. Wait for Auto Reconnect or reselect the host.")
        case .handshakeFailed:
            return text("在终端验证中查看具体握手错误，请管理员核对服务端 SSH 日志和算法兼容性；不要为消除报错盲目启用弱算法。处理后重新选择原主机。", "Inspect the handshake error in Terminal; ask the administrator to check server SSH logs and algorithm compatibility. Do not blindly enable weak algorithms. Then reselect the host.")
        case .noControlConnection:
            return text("重新选择原主机建立连接，再开启端口；若反复中断，用终端验证检查网络和 SSH 服务。", "Reselect the host to establish a connection, then start the ports. If it keeps dropping, verify the network and SSH service in Terminal.")
        case .ssh, .unknown:
            return text("在界面悬停错误并用终端验证查看具体原因。本诊断有意省略 SSH 原文；需要分享时先手动隐藏主机、地址、路径和凭据。", "Inspect the error tooltip and verify in Terminal. Raw SSH output is deliberately omitted; redact hosts, addresses, paths, and credentials before sharing details.")
        }
    }
}
