// swift-tools-version:6.0
import PackageDescription

// 编译 App 的原始 Model/Services 与邮件视图，验证实际调用点和无窗口布局；不投递系统通知。
let package = Package(
    name: "FeishuLiteStateTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "FeishuLiteCore")],
    targets: [
        .target(name: "FeishuLiteState", dependencies: ["FeishuLiteCore"], path: "FeishuLite",
                exclude: ["App", "Assets.xcassets", "Info.plist", "FeishuLite.entitlements",
                          "UI/RootView.swift"],
                sources: ["Model", "Services", "UI/MailPlainBody.swift", "UI/EmailWorkspace.swift",
                          "UI/MailInboxList.swift", "UI/MailMessageDetail.swift", "UI/ScrollAnchors.swift",
                          "UI/MainView.swift", "UI/ComposerView.swift", "UI/ImageMessageView.swift",
                          "UI/ConversationView.swift", "UI/ChatListView.swift", "UI/ShellComponents.swift",
                          "UI/LoginView.swift"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FeishuLiteStateTests", dependencies: ["FeishuLiteState", "FeishuLiteCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
