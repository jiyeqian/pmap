// I18nTests.swift
// 双语查表与错误映射的单元测试（Swift Testing 框架）

import Testing
import Foundation
@testable import PmapCore

// MARK: - 文案表完整性

@Suite("文案表 L10n")
struct L10nTests {

    @Test("每个键在中文与英文表中都有非空条目（无漏译）")
    func allKeysTranslated() {
        for key in L10n.Key.allCases {
            #expect(L10n.isTranslated(key, .zh), "中文缺词：\(key.rawValue)")
            #expect(L10n.isTranslated(key, .en), "英文缺词：\(key.rawValue)")
        }
    }

    @Test("查表按语言返回不同文案")
    func textByLanguage() {
        #expect(L10n.text(.quit, .zh) == "退出")
        #expect(L10n.text(.quit, .en) == "Quit")
        #expect(L10n.text(.hostOn, .zh) == "连通")
        #expect(L10n.text(.hostOn, .en) == "On")
    }

    @Test("带参数文案在两种语言下均正确替换")
    func formattedText() {
        let zh = L10n.text(.errPortBusy, .zh, 8080, "nginx")
        let en = L10n.text(.errPortBusy, .en, 8080, "nginx")
        #expect(zh.contains("8080") && zh.contains("nginx"))
        #expect(en.contains("8080") && en.contains("nginx"))
    }

    @Test("通知文案模板参数替换正确")
    func notifyTemplate() {
        let body = L10n.text(.notifyReconnectedBody, .en, "myhost", 3)
        #expect(body.contains("myhost"))
        #expect(body.contains("3"))
    }
}

// MARK: - 语言

@Suite("语言 Lang")
struct LangTests {

    @Test("rawValue 解析与非法值返回 nil")
    func rawValue() {
        #expect(Lang(rawValue: "zh") == .zh)
        #expect(Lang(rawValue: "en") == .en)
        #expect(Lang(rawValue: "fr") == nil)
    }

    @Test("语言标签与互为另一种语言")
    func tagAndOther() {
        #expect(Lang.zh.tag == "中")
        #expect(Lang.en.tag == "EN")
        #expect(Lang.zh.other == .en)
        #expect(Lang.en.other == .zh)
    }

    @Test("系统默认语言可判定")
    func systemDefault() {
        // 仅断言结果属于合法集合，避免依赖运行机器的实际语言
        #expect([Lang.zh, .en].contains(Lang.system))
    }
}

// MARK: - 错误分类与描述

@Suite("错误分类 PortError")
struct PortErrorTests {

    @Test("端口被占用 → localPortBusy")
    func classifyBusy() {
        let e = PortError.classify("bind: Address already in use", localPort: 8080)
        #expect(e == .localPortBusy(port: 8080, by: nil))
    }

    @Test("服务端禁止转发 → forwardingNotAllowed")
    func classifyNotAllowed() {
        let e = PortError.classify("channel_setup_fwd_listener_tcpip: administratively prohibited: open failed", localPort: 80)
        #expect(e == .forwardingNotAllowed)
    }

    @Test("认证失败与认证次数过多分别归类")
    func classifyAuth() {
        #expect(PortError.classify("Permission denied (publickey).", localPort: 80) == .authFailed)
        #expect(PortError.classify("Too many authentication failures", localPort: 80) == .tooManyAuthFailures)
    }

    @Test("主机密钥校验失败单独归类")
    func classifyHostKey() {
        #expect(PortError.classify("Host key verification failed.", localPort: 80) == .hostKeyRejected)
    }

    @Test("连接被拒 / 超时 / 找不到主机分别归类")
    func classifyNetwork() {
        #expect(PortError.classify("ssh: connect to host h port 22: Connection refused", localPort: 80) == .connectionRefused)
        #expect(PortError.classify("ssh: connect to host h port 22: Operation timed out", localPort: 80) == .timedOut)
        #expect(PortError.classify("ssh: Could not resolve hostname h: nodename nor servname", localPort: 80) == .hostNotFound)
    }

    @Test("open failed + Connection refused 应判为连接被拒（不得误判为禁止转发）")
    func classifyOrdering() {
        let raw = "channel 2: open failed: connect failed: Connection refused"
        #expect(PortError.classify(raw, localPort: 80) == .connectionRefused)
    }

    @Test("复用通道不可用 / 握手失败分别归类")
    func classifyControlAndHandshake() {
        #expect(PortError.classify("Control socket connect(/Users/x/.ssh/pmap-control/h): No such file or directory", localPort: 80) == .noControlConnection)
        #expect(PortError.classify("kex_exchange_identification: Connection closed by remote host", localPort: 80) == .handshakeFailed)
    }

    @Test("未识别原文 → ssh(raw:) 且截断到 60 字符并加省略号")
    func classifyUnknownTruncates() {
        let raw = String(repeating: "x", count: 200)
        guard case .ssh(let s) = PortError.classify(raw, localPort: 80) else {
            Issue.record("期望落入 .ssh(raw:)")
            return
        }
        #expect(s.count == PortError.rawMaxLength + 1)
        #expect(s.hasSuffix("…"))
    }

    @Test("空报错 → unknown")
    func classifyEmpty() {
        #expect(PortError.classify("   ", localPort: 80) == .unknown)
    }

    @Test("描述按语言生成，含端口号与进程名")
    func descriptionLocalized() {
        let zh = PortError.localPortBusy(port: 8080, by: "nginx").description(.zh)
        let en = PortError.localPortBusy(port: 8080, by: "nginx").description(.en)
        #expect(zh.contains("8080") && zh.contains("nginx"))
        #expect(en.contains("8080") && en.contains("nginx"))
        #expect(zh != en)
    }

    @Test("占用进程未知时用兜底词")
    func descriptionBusyFallback() {
        let zh = PortError.localPortBusy(port: 8080, by: nil).description(.zh)
        let en = PortError.localPortBusy(port: 8080, by: nil).description(.en)
        #expect(zh.contains("其他进程"))
        #expect(en.contains("another process"))
    }

    @Test("未知原文描述带原文且已截断")
    func descriptionRaw() {
        let raw = String(repeating: "y", count: 200)
        let d = PortError.classify(raw, localPort: 80).description(.en)
        #expect(d.hasPrefix("Error:"))
        #expect(d.count < 100)
    }
}
