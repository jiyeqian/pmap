// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pmap",
    platforms: [.macOS(.v14)],
    targets: [
        // 可测试核心（不含应用入口与设置视图），供单元测试引用
        // 应用入口与设置视图由 build.sh / Xcode 编译
        .target(
            name: "PmapCore",
            path: "Sources",
            exclude: ["Pmap.swift", "SettingsView.swift"]
        ),
        .testTarget(
            name: "PmapCoreTests",
            dependencies: ["PmapCore"],
            path: "Tests"
        ),
    ]
)
