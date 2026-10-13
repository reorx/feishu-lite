// swift-tools-version:6.0
import PackageDescription

// 编译 App 的原始 Model/Services 与邮件视图，验证实际调用点和无窗口布局；不投递系统通知。
let package = Package(
    name: "FeishuChatStateTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "FeishuChatCore")],
    targets: [
        .target(name: "FeishuChatState", dependencies: ["FeishuChatCore"], path: "FeishuChat",
                exclude: ["App", "Assets.xcassets", "Info.plist", "FeishuChat.entitlements",
                          "UI/MainView.swift", "UI/ComposerView.swift",
                          "UI/ImageMessageView.swift", "UI/RootView.swift", "UI/LoginView.swift",
                          "UI/ConversationView.swift", "UI/ChatListView.swift"],
                sources: ["Model", "Services", "UI/MailPlainBody.swift", "UI/EmailWorkspace.swift",
                          "UI/MailInboxList.swift", "UI/MailMessageDetail.swift", "UI/ScrollAnchors.swift"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FeishuChatStateTests", dependencies: ["FeishuChatState", "FeishuChatCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
