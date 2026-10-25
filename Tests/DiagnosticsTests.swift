import Foundation
import Testing
@testable import PmapCore

@Suite("脱敏诊断与恢复引导")
@MainActor
struct DiagnosticsTests {
    private func store() -> Store {
        Store(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"), scanHosts: false)
    }

    @Test("主机失败不会被正常的文件和存储状态掩盖")
    func hostKeyFailure() {
        let s = store()
        s.setLang(.zh, persist: false)
        s.config.trustedConfig = true
        s.activeHost = "PRIVATE-HOST"
        s.hostState["PRIVATE-HOST"] = .failed
        s.hostError = .hostKeyRejected
        let report = s.redactedDiagnostics
        #expect(report.contains("Status: attention_required"))
        #expect(report.contains("Host state: failed"))
        #expect(report.contains("Host error: host_key_rejected"))
        #expect(report.contains("Storage error: false"))
        #expect(report.contains("Access error: false"))
        #expect(report.contains("known_hosts"))
        #expect(report.contains("不要删除整个"))
        #expect(report.contains("终端验证"))
        #expect(!report.contains("PRIVATE-HOST"))
    }

    @Test("所有错误类别有恢复路径，不输出关联的路径端口进程或原文")
    func categoriesAndRedaction() {
        let s = store()
        s.setLang(.en, persist: false)
        let failures: [PortError] = [.localPortBusy(port: 54321, by: "SECRET-PROCESS"), .forwardingNotAllowed,
            .authFailed, .fileAccess(path: "/SECRET-PATH/key"), .tooManyAuthFailures, .connectionRefused,
            .timedOut, .sshConnectTimeout, .hostNotFound, .hostKeyRejected, .handshakeFailed,
            .noControlConnection, .ssh(raw: "SECRET-RAW token=private 192.0.2.123"), .unknown]
        #expect(Set(failures.map(\.diagnosticCode)).count == failures.count)
        s.config.host = "SECRET-SAVED-HOST"
        s.config.sshConfigFile = "/SECRET-CONFIG/config"
        s.adhoc = [Rule(local: 54321, remote: 54322, note: "SECRET-NOTE")]
        s.hostAliases = ["SECRET-ALIAS"]
        for failure in failures {
            s.hostError = failure
            s.errors = [54321: failure, 54322: failure]
            let report = s.redactedDiagnostics
            #expect(report.contains("Host error: " + failure.diagnosticCode))
            #expect(report.contains(failure.diagnosticCode + "=2"))
            #expect(report.contains("Port errors: 2"))
            #expect(report.contains("Recovery steps:"))
            #expect(!failure.recoverySteps(.zh).isEmpty)
            #expect(!failure.recoverySteps(.en).isEmpty)
            for secret in ["SECRET-", "54321", "54322", "192.0.2.123", "token=private"] {
                #expect(!report.contains(secret))
            }
        }
    }

    @Test("配置缺失和损坏存储有独立恢复说明且不泄露文件名")
    func configurationFailures() {
        let s = store()
        s.setLang(.en, persist: false)
        s.selectConfiguration(URL(fileURLWithPath: "/PRIVATE-MISSING/config"))
        s.storageIssue = true
        let report = s.redactedDiagnostics
        #expect(report.contains("Configuration error: file_missing"))
        #expect(report.contains("Storage error: true"))
        #expect(report.contains("Back it up"))
        #expect(report.contains("Check the config file"))
        #expect(!report.contains("PRIVATE-MISSING"))
    }

    @Test("未连接、连接中、连通和缺少错误类别均如实报告")
    func states() {
        let s = store()
        s.setLang(.en, persist: false)
        #expect(s.redactedDiagnostics.contains("Status: configuration_trust_required"))
        s.config.trustedConfig = true
        #expect(s.redactedDiagnostics.contains("Status: idle"))
        s.activeHost = "private"
        s.hostState["private"] = .connecting
        #expect(s.redactedDiagnostics.contains("Status: working"))
        s.hostState["private"] = .on
        #expect(s.redactedDiagnostics.contains("Status: connected_service_unverified"))
        #expect(!s.redactedDiagnostics.contains("Green does not guarantee"))
        #expect(!s.redactedDiagnostics.contains("Recovery steps:"))
        #expect(!s.redactedDiagnostics.contains("No fault is currently recorded"))
        #expect(!s.redactedDiagnostics.contains("This report performs no repairs"))
        s.hostState["private"] = .failed
        #expect(s.redactedDiagnostics.contains("Status: attention_required"))
        #expect(s.redactedDiagnostics.contains("Host failed without an error category"))
    }
}
