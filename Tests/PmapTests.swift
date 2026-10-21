// PmapTests.swift
// 纯函数单元测试（Swift Testing 框架）

import Testing
import Foundation
@testable import PmapCore

// MARK: - parseQuickInput

@Suite("万能输入解析 parseQuickInput")
struct ParseQuickInputTests {

    @Test("单端口：8000 → local 8000 remote 8000，无备注")
    func singlePort() {
        let r = parseQuickInput("8000")
        #expect(r != nil)
        #expect(r?.rule.local == 8000)
        #expect(r?.rule.remote == 8000)
        #expect(r?.rule.note == nil)
    }

    @Test("port:port：8000:80 → local 8000 remote 80")
    func portPair() {
        let r = parseQuickInput("8000:80")
        #expect(r?.rule.local == 8000)
        #expect(r?.rule.remote == 80)
        #expect(r?.rule.note == nil)
    }

    @Test("#备注：5432:5432#数据库 → note 数据库")
    func noteSuffix() {
        let r = parseQuickInput("5432:5432#数据库")
        #expect(r?.rule.note == "数据库")
    }

    @Test("单端口#备注：5432#数据库 → note 数据库")
    func singlePortNote() {
        let r = parseQuickInput("5432#数据库")
        #expect(r?.rule.local == 5432)
        #expect(r?.rule.remote == 5432)
        #expect(r?.rule.note == "数据库")
    }

    @Test("#后空白：5432#   → note nil")
    func noteWhitespace() {
        let r = parseQuickInput("5432#   ")
        #expect(r?.rule.note == nil)
    }

    @Test("#空备注：5432# → note nil")
    func noteEmpty() {
        let r = parseQuickInput("5432#")
        #expect(r?.rule.note == nil)
    }

    @Test("@组名：8000@dev → group dev（历史遗留，实际不使用）")
    func atGroup() {
        let r = parseQuickInput("8000@dev")
        #expect(r?.group == "dev")
    }

    @Test("非法端口 0 / 65536 / 负数 → nil")
    func invalidPorts() {
        #expect(parseQuickInput("0") == nil)
        #expect(parseQuickInput("65536") == nil)
        #expect(parseQuickInput("-1") == nil)
    }

    @Test("非数字 / 空串 / 多冒号 / 非数字远端 → nil")
    func malformed() {
        #expect(parseQuickInput("abc") == nil)
        #expect(parseQuickInput("") == nil)
        #expect(parseQuickInput("8000:80:90") == nil)
        #expect(parseQuickInput("8000:abc") == nil)
    }

    @Test("含空格：80 00 → nil")
    func containsSpace() {
        #expect(parseQuickInput("80 00") == nil)
    }

    @Test("前后空白 trim 后仍可解析")
    func trimsWhitespace() {
        let r = parseQuickInput("  8000  ")
        #expect(r?.rule.local == 8000)
    }
}

// MARK: - isValidPort

@Suite("端口校验 isValidPort")
struct IsValidPortTests {

    @Test("边界值")
    func boundaries() {
        #expect(isValidPort(0) == false)
        #expect(isValidPort(1) == true)
        #expect(isValidPort(65535) == true)
        #expect(isValidPort(65536) == false)
        #expect(isValidPort(-1) == false)
    }
}

// MARK: - SSHConfig.parseHosts

@Suite("SSH 配置解析 parseHosts")
struct ParseHostsTests {

    @Test("基本 Host 别名")
    func basicHost() {
        let text = "Host myserver\n    HostName 1.2.3.4\n"
        #expect(SSHConfig.parseHosts(text) == ["myserver"])
    }

    @Test("一行多别名")
    func multiAlias() {
        let text = "Host a b c\n"
        #expect(SSHConfig.parseHosts(text) == ["a", "b", "c"])
    }

    @Test("逗号分隔别名")
    func commaAlias() {
        let text = "Host a,b,c\n"
        #expect(SSHConfig.parseHosts(text) == ["a", "b", "c"])
    }

    @Test("跳过通配符 * ? !")
    func skipWildcards() {
        let text = "Host *.example.com\nHost ?x\nHost !y\nHost good\n"
        #expect(SSHConfig.parseHosts(text) == ["good"])
    }

    @Test("显示含点地址")
    func skipDotted() {
        let text = "Host github.com\nHost plain\n"
        #expect(SSHConfig.parseHosts(text) == ["github.com", "plain"])
    }

    @Test("跳过本机别名（selfAliases）")
    func skipSelfAlias() {
        let text = "Host local\nHost real\n"
        #expect(SSHConfig.parseHosts(text, selfAliases: ["local"]) == ["real"])
    }

    @Test("去重")
    func dedupe() {
        let text = "Host x\nHost x\nHost x\n"
        #expect(SSHConfig.parseHosts(text) == ["x"])
    }

    @Test("空文本 / 注释行 / 非 Host 行")
    func emptyAndComments() {
        #expect(SSHConfig.parseHosts("") == [])
        #expect(SSHConfig.parseHosts("# comment\n\nHostName foo\n") == [])
    }

    @Test("Host 大小写不敏感")
    func caseInsensitive() {
        let text = "host myserver\n"
        #expect(SSHConfig.parseHosts(text) == ["myserver"])
    }
}
