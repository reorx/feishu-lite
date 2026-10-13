// swift-tools-version:6.0
import PackageDescription

// 编译 App 的原始 Model/Services，自动验证实际调用点；不启动窗口或系统通知。
let package = Package(
    name: "FeishuChatStateTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "FeishuChatCore")],
    targets: [
        .target(name: "FeishuChatState", dependencies: ["FeishuChatCore"], path: "FeishuChat",
                exclude: ["App", "UI", "Assets.xcassets", "Info.plist", "FeishuChat.entitlements"],
                sources: ["Model", "Services"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FeishuChatStateTests", dependencies: ["FeishuChatState", "FeishuChatCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
