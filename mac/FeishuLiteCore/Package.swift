// swift-tools-version:6.0
import PackageDescription

// 语言模式固定 Swift 5（避免 Swift 6 strict concurrency 的迁移成本），
// tools-version 6.0 以使用 Swift Testing
let package = Package(
    name: "FeishuLiteCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FeishuLiteCore", targets: ["FeishuLiteCore"])
    ],
    dependencies: [
        // 第三方依赖统一声明在这里，app target 经 project.yml 传递依赖
        // 例：.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "FeishuLiteCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FeishuLiteCoreTests",
            dependencies: ["FeishuLiteCore"],
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
