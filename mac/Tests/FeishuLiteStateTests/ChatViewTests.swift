import AppKit
import SwiftUI
import Testing
import FeishuLiteCore
@testable import FeishuLiteState

/// R9：聊天详情里的界面行为，用无窗口 NSHostingView 驱动生产视图。
@MainActor
@Suite(.serialized)
struct ChatViewTests {
    private func composerScrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
        return view.subviews.lazy.compactMap { composerScrollView($0) }.first
    }

    private func layout(_ host: NSView) async throws {
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func conversation(draft: String) -> Conversation {
        let chat = Chat(id: "composer-chat", name: "合成会话", type: .group, unread: 0, muted: false,
                        lastMessagePreview: "", lastMessageTime: 1)
        return Conversation(chat: chat, draft: draft, connection: BackendConnection())
    }

    /// U1-02：发送会把草稿清空，程序写入草稿也走同一条路径；输入框高度都要跟着变。
    @Test func composerHeightFollowsProgrammaticDraftChanges() async throws {
        let model = conversation(draft: "")
        let host = NSHostingView(rootView: ComposerView(conversation: model))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await layout(host)
        let input = try #require(composerScrollView(host))
        let oneLine = input.frame.height
        #expect(abs(oneLine - ComposerTextView.minHeight) < 1)

        model.draft = "第一行\n第二行\n第三行\n第四行"
        try await layout(host)
        let fourLines = input.frame.height
        #expect(fourLines > oneLine + 40, "程序写入的多行草稿没有撑高输入框：\(fourLines)")

        // 发送成功后 Conversation 把草稿置空
        model.draft = ""
        try await layout(host)
        #expect(abs(input.frame.height - oneLine) < 1, "清空草稿后输入框没有缩回一行：\(input.frame.height)")
    }
}
