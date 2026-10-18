// Shell.swift
// 进程执行封装：运行命令、SSH、端口占用检测

import Foundation

// MARK: - Shell

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static func ssh(_ args: [String]) -> (code: Int32, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "\(error)") }
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: e, encoding: .utf8) ?? "")
    }

    /// 本地端口是否被占用
    static func portBusy(_ port: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard !text.isEmpty else { return nil }
        // 解析进程名
        for line in text.components(separatedBy: .newlines).dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count > 1 { return parts[1] }
        }
        return "unknown"
    }
}
