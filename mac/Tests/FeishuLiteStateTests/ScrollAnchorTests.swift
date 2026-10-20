import Observation
import AppKit
import SwiftUI
import Testing
import FeishuLiteCore
@testable import FeishuLiteState

@MainActor
@Suite(.serialized)
struct ScrollAnchorTests {
    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(35))
    }
}

private final class ScrollMessagesProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var images: Set<String> = []
    static var loadedImages: Set<String> { lock.withLock { images } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let chatID = request.url!.path.components(separatedBy: "/")[2]
        if request.url!.path.hasSuffix("/image") {
            Self.lock.withLock { _ = Self.images.insert(chatID) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCr0AAAAASUVORK5CYII=")!)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "before_position" })?.value.flatMap(Int.init)
        let positions = chatID == "chat-history" ? ((before ?? 91) - 30)..<(before ?? 91) : 1..<41
        let page = positions.map { position in
            if chatID == "chat-images", position == 1 || position == 40 {
                return Message(id: "\(chatID)-\(position)", chatID: chatID, position: position, senderID: "sender",
                               senderName: "合成用户", isSelf: false, createTime: 1, type: "image", text: "img", badged: true)
            }
            return scrollMessage(position, chatID: chatID)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! BackendJSON.encoder.encode(page))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func scrollMessage(_ position: Int, chatID: String = "chat-a") -> Message {
    Message(id: "\(chatID)-\(position)", chatID: chatID, position: position, senderID: "sender",
            senderName: "合成用户", isSelf: false, createTime: 1, type: "text",
            text: "滚动回归消息 \(position)", badged: true)
}

@MainActor private final class ScrollNotifications: MessageNotifications {
    func notify(message: Message, chat: Chat) {}
    func notifySessionExpired() {}
    func clearSessionExpired() {}
    func clearNotifications(chatID: String) {}
}

@MainActor private final class ScrollCredentials: MailCredentialStore {
    func read(accountID: String) throws -> MailSecret { throw MailKeychainError.notFound }
    func write(_ secret: MailSecret, accountID: String, address: String) throws {}
    func delete(accountID: String) throws {}
}

@MainActor extension ScrollAnchorTests {
    private func scrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, !(scroll.documentView is NSTextView) { return scroll }
        let candidates = view.subviews.compactMap { scrollView($0) }
        return candidates.max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
    }

    private func layout(_ host: NSView) async throws {
        for _ in 0..<15 { try await settle(host) }
    }

    private func scroll(_ scroll: NSScrollView, to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func conversation(_ id: String, connection: BackendConnection) async -> Conversation {
        let chat = Chat(id: id, name: "合成会话", type: .group, unread: 0, muted: false,
                        lastMessagePreview: "", lastMessageTime: 1, lastPosition: 40)
        let conversation = Conversation(chat: chat, draft: "", connection: connection)
        await conversation.loadLatest(chatLastPosition: 40)
        return conversation
    }

    @Test func conversationFollowsBottomAndKeepsHistoryAcrossReconstruction() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScrollMessagesProtocol.self]
        let connection = BackendConnection()
        connection.client = BackendClient(endpoint: BackendEndpoint(baseURL: URL(string: "http://scroll.invalid")!, token: "synthetic"),
                                          session: URLSession(configuration: config))
        let messages = MessagesState(connection: connection, notifications: ScrollNotifications())
        let a = await conversation("chat-a", connection: connection)
        let b = await conversation("chat-b", connection: connection)
        let host = NSHostingView(rootView: AnyView(ConversationView(conversation: a, title: "A", messages: messages)))
        defer { host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded() }
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await layout(host)
        var view = try #require(scrollView(host))
        a.receive(scrollMessage(41))
        try await layout(host)
        #expect(messages.detailScrollAnchors["chat-a"] == "bottom")
        #expect(view.documentVisibleRect.maxY >= view.documentView!.bounds.height - 10)

        // Resizing without changing the visible row must not invalidate
        // consumers of the persisted anchor on every layout pass.
        var invalidated = false
        withObservationTracking { _ = messages.detailScrollAnchors } onChange: { invalidated = true }
        for width in [610, 620, 600] {
            host.frame.size.width = CGFloat(width)
            try await layout(host)
        }
        #expect(!invalidated, "Unchanged detail anchor was published again during layout")

        scroll(view, to: 500)
        try await layout(host)
        let anchor = try #require(messages.detailScrollAnchors["chat-a"])
        #expect(anchor != "bottom")
        let offset = view.documentVisibleRect.minY
        a.receive(scrollMessage(42))
        try await layout(host)
        #expect(abs(view.documentVisibleRect.minY - offset) < 2)
        #expect(messages.detailScrollAnchors["chat-a"] == anchor)

        // Switching conversations destroys the detail view, as does switching
        // modules. Neither may overwrite the retired conversation's cache.
        host.rootView = AnyView(ConversationView(conversation: b, title: "B", messages: messages).id("chat-b"))
        try await layout(host)
        #expect(messages.detailScrollAnchors["chat-a"] == anchor)
        host.rootView = AnyView(ConversationView(conversation: a, title: "A", messages: messages).id("chat-a"))
        try await layout(host)
        view = try #require(scrollView(host))
        #expect(abs(view.documentVisibleRect.minY - offset) < 65) // saved row, not pixel offset
        host.rootView = AnyView(EmptyView())
        try await layout(host)
        host.rootView = AnyView(ConversationView(conversation: a, title: "A", messages: messages).id("chat-a"))
        try await layout(host)
        view = try #require(scrollView(host))
        #expect(abs(view.documentVisibleRect.minY - offset) < 65)
        #expect(messages.detailScrollAnchors["chat-a"] == anchor)
    }

    @Test func olderPagesLoadOnlyWhenTheirHeaderBecomesVisible() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScrollMessagesProtocol.self]
        let connection = BackendConnection()
        connection.client = BackendClient(endpoint: BackendEndpoint(baseURL: URL(string: "http://scroll.invalid")!, token: "synthetic"),
                                          session: URLSession(configuration: config))
        let messages = MessagesState(connection: connection, notifications: ScrollNotifications())
        let conversation = await conversation("chat-history", connection: connection)
        let host = NSHostingView(rootView: AnyView(ConversationView(conversation: conversation, title: "分页", messages: messages)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { host.rootView = AnyView(EmptyView()); window.contentView = nil }
        try await layout(host)
        #expect(conversation.rows.first?.message.position == 61)

        let view = try #require(scrollView(host))
        for firstPosition in [31, 1] {
            scroll(view, to: 0)
            try await layout(host)
            #expect(conversation.rows.first?.message.position == firstPosition)
            #expect(conversation.rows.last?.message.position == 90)
            // The row that used to start the page stays visible after prepend.
            #expect(messages.detailScrollAnchors["chat-history"] == "chat-history-\(firstPosition + 30)")
        }
    }

    @Test func imagesLoadOnlyWhenTheirRowsAreVisible() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScrollMessagesProtocol.self]
        let connection = BackendConnection()
        connection.client = BackendClient(endpoint: BackendEndpoint(baseURL: URL(string: "http://scroll.invalid")!, token: "synthetic"),
                                          session: URLSession(configuration: config))
        let messages = MessagesState(connection: connection, notifications: ScrollNotifications())
        let conversation = await conversation("chat-images", connection: connection)
        let host = NSHostingView(rootView: AnyView(ConversationView(conversation: conversation, title: "图片", messages: messages)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { host.rootView = AnyView(EmptyView()); window.contentView = nil }
        try await layout(host)
        #expect(ScrollMessagesProtocol.loadedImages.contains("chat-images-40"))
        #expect(!ScrollMessagesProtocol.loadedImages.contains("chat-images-1"))
        let view = try #require(scrollView(host))
        scroll(view, to: 0)
        try await layout(host)
        #expect(ScrollMessagesProtocol.loadedImages.contains("chat-images-1"))
    }

    private func verifyListRestoration(_ makeView: () -> AnyView, anchor: () -> String?) async throws {
        let host = NSHostingView(rootView: makeView())
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { host.rootView = AnyView(EmptyView()); window.contentView = nil }
        try await layout(host)
        let original = try #require(scrollView(host))
        scroll(original, to: 700)
        try await layout(host)
        let saved = try #require(anchor())
        let offset = original.documentVisibleRect.minY
        #expect(offset > 600)
        host.rootView = AnyView(EmptyView())
        try await layout(host)
        #expect(anchor() == saved)
        host.rootView = makeView()
        try await layout(host)
        let returned = try #require(scrollView(host))
        #expect(abs(returned.documentVisibleRect.minY - offset) < 90)
        #expect(anchor() == saved)
    }

    @Test func chatListRestoresAfterModuleSwitch() async throws {
        let messages = MessagesState(connection: BackendConnection(), notifications: ScrollNotifications())
        for i in 0..<60 {
            messages.handle(.chatUpdated(Chat(id: "chat-\(i)", name: "合成会话 \(i)", type: .group,
                                              unread: 0, muted: false, lastMessagePreview: "摘要",
                                              lastMessageTime: 1000 - i, lastPosition: 1)))
        }
        try await verifyListRestoration({ AnyView(ChatListView(messages: messages, status: SidebarStatus(tone: .healthy, text: "在线"), switcher: ModuleSwitcher(activeModule: .messages, counts: UnreadCounts(messages: 0, email: 0), select: { _ in }))) },
                                        anchor: { messages.listScrollAnchors[false] })
    }

    @Test func mailListRestoresAfterModuleSwitch() async throws {
        let suite = "scroll-tests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let mail = MailState(connection: BackendConnection(), credentials: ScrollCredentials(),
                             externalBackend: true, preferences: preferences)
        mail.hasLoadedList = true
        let rows: [[String: Any]] = (0..<60).map { i in
            ["id": "mail-\(i)", "key": ["account_id": "synthetic", "folder_id": "INBOX", "uidvalidity": 1, "uid": i + 1],
             "subject": "合成邮件 \(i)", "sender": [], "to": [], "cc": [], "date": "", "message_id": "",
             "received_at": 0, "size": 1, "flags": [], "unread": false, "attachments": [],
             "body_part": NSNull(), "error": NSNull()]
        }
        mail.items = try BackendJSON.decoder.decode([MailSummary].self, from: JSONSerialization.data(withJSONObject: rows))
        try await verifyListRestoration({ AnyView(MailInboxList(mail: mail, status: mail.sidebarStatus(now: Date()), switcher: ModuleSwitcher(activeModule: .email, counts: UnreadCounts(messages: 0, email: 0), select: { _ in }))) }, anchor: { mail.listScrollAnchor })
    }
}
