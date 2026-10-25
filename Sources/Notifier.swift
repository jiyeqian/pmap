import Foundation
@preconcurrency import UserNotifications

// MARK: - 系统通知

enum ConnectionNotice: Equatable {
    case disconnected
    case reconnected(host: String, ports: Int)
    case portsRestored(Int)
}

enum Notifier {
    static func post(_ notice: ConnectionNotice, lang: Lang) {
        switch notice {
        case .disconnected:
            post(title: L10n.text(.notifyDisconnected, lang), body: L10n.text(.connectionLost, lang))
        case .reconnected(_, let ports):
            post(title: L10n.text(.notifyReconnected, lang), body: L10n.text(.notifyReconnectedSummary, lang, ports))
        case .portsRestored(let count):
            post(title: L10n.text(.notifyPortsRestored, lang), body: L10n.text(.notifyPortsRestoredBody, lang, count))
        }
    }

    /// 通知显示由系统授权控制。
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
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            if allowed { center.add(request) }
        }
    }
}

