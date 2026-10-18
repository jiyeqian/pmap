// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pmap",
    targets: [
        // 纯逻辑核心（无 UI/无 @main），供单元测试引用
        // 排除 Pmap.swift（含 @main 入口 + SwiftUI/AppKit 依赖，由 build.sh 单独编译）
        .target(
            name: "PmapCore",
            path: "Sources",
            exclude: ["Pmap.swift"]
        ),
        .testTarget(
            name: "PmapCoreTests",
            dependencies: ["PmapCore"],
            path: "Tests"
        ),
    ]
)
