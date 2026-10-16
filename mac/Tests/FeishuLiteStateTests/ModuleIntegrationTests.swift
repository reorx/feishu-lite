import AppKit
import Foundation
import FeishuLiteCore
import Testing
@testable import FeishuLiteState

private final class LocalBackend: URLProtocol {
    private static let lock = NSLock()
    private static var paths: [String] = []
    private static var conflictBody: String?

    static func reset(conflict: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        paths = []
        conflictBody = conflict
    }

    static func count(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.filter { $0 == path }.count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let path = request.url!.path
        Self.paths.append(path)
        let conflict = Self.conflictBody
        Self.lock.unlock()
        let body: Data
        let status: Int
        if let conflict {
            status = 409
            body = Data(conflict.utf8)
        } else {
            status = 200
            switch path {
            case "/chats/chat/messages": body = try! BackendJSON.encoder.encode([sampleMessage()])
            case "/chats": body = try! BackendJSON.encoder.encode([sampleChat()])
            case "/login/qr": body = Data(#"{"qr_content":"isolated-test"}"#.utf8)
            default: body = Data("{}".utf8)
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func sampleChat(unread: Int = 2) -> Chat {
    Chat(id: "chat", name: "隔离会话", type: .group, unread: unread, muted: false,
         lastMessagePreview: "测试", lastMessageTime: 1, lastPosition: 1)
}

private func sampleMessage() -> Message {
    Message(id: "message", chatID: "chat", position: 1, senderID: "sender", senderName: "测试",
            isSelf: false, createTime: 1, type: "text", text: "隔离样本", badged: true)
}

@MainActor
private final class NotificationRecorder: MessageNotifications {
    var incoming = 0
    var cleared = 0
    func notify(message: Message, chat: Chat) { incoming += 1 }
    func notifySessionExpired() {}
    func clearSessionExpired() {}
    func clearNotifications(chatID: String) { cleared += 1 }
}

@MainActor
private final class WindowRecorder: AppWindows {
    var window: NSWindow? { nil }
    var isShowingContent: Bool { false }
    var shown = 0
    func show() { shown += 1 }
}

@MainActor
private func connection() -> BackendConnection {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LocalBackend.self]
    let connection = BackendConnection()
    connection.client = BackendClient(endpoint: BackendEndpoint(baseURL: URL(string: "http://isolated.invalid")!, token: "test-only"),
                                      session: URLSession(configuration: config))
    return connection
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("隔离调用在 1 秒内未完成")
}

@Suite(.serialized)
@MainActor
struct ModuleIntegrationTests {
    @Test func rapidlyReturningToMessagesDoesNotLoseLoginTaskOwnership() async throws {
        LocalBackend.reset()
        let login = LoginModel(connection: connection())
        defer { login.end() }
        login.begin()
        login.end()
        login.begin()
        try await waitUntil {
            if case .waiting = login.phase { return true }
            return false
        }
        let started = LocalBackend.count("/login/qr")
        login.begin()
        try await Task.sleep(for: .milliseconds(50))
        #expect(LocalBackend.count("/login/qr") == started)
    }

    @Test func realMessagesStateDoesNotReadInEmailAndReadsWhenReturning() async throws {
        LocalBackend.reset()
        let recorder = NotificationRecorder()
        let messages = MessagesState(connection: connection(), notifications: recorder)
        var reportedUnread: [Int] = []
        messages.onUnreadCountChange = { reportedUnread.append($0) }
        var module = AppModule.email
        messages.viewingContext = { [weak messages] in
            ViewingContext(activeModule: module, isAppActive: true, isWindowVisible: true,
                           selectedChatID: messages?.selectedChatID)
        }
        messages.handle(.status(BackendStatus(state: .online, user: User(id: "isolated-user", name: "测试"))))
        messages.handle(.chatUpdated(sampleChat()))
        messages.selectedChatID = "chat"
        try await waitUntil { messages.conversation?.hasLoaded == true }
        messages.conversation?.draft = "保留草稿"
        messages.listScrollAnchors[false] = "chat"
        messages.detailScrollAnchors["chat"] = "message"
        messages.handle(.messageNew(message: sampleMessage(), chat: sampleChat()))
        await messages.refreshAfterConnect()
        messages.markReadIfViewing(onlyIfUnread: true)
        #expect(LocalBackend.count("/chats/chat/read") == 0)
        #expect(messages.unreadCount == 2)
        #expect(recorder.incoming == 1)
        #expect(recorder.cleared == 0)
        let selected = messages.conversation
        module = .messages
        messages.markReadIfViewing(onlyIfUnread: true)
        try await waitUntil { LocalBackend.count("/chats/chat/read") == 1 }
        #expect(messages.unreadCount == 0)
        #expect(recorder.cleared == 1)
        #expect(messages.conversation === selected)
        #expect(messages.conversation?.draft == "保留草稿")
        #expect(messages.listScrollAnchors[false] == "chat")
        #expect(messages.detailScrollAnchors["chat"] == "message")
        #expect(reportedUnread.last == 0)
    }

    @Test func actualBackendClientPreservesNonLogoutConflictAndConversationDisplaysIt() async throws {
        LocalBackend.reset(conflict: #"{"detail":"resource_conflict"}"#)
        let connection = connection()
        let conversation = Conversation(chat: sampleChat(), draft: "", connection: connection)
        await conversation.loadLatest(chatLastPosition: 1)
        #expect(conversation.loadError?.contains("409") == true)
        #expect(!conversation.hasLoaded)
        LocalBackend.reset(conflict: #"{"detail":"logged_out"}"#)
        await conversation.loadLatest(chatLastPosition: 1)
        // 已有冲突提示未被覆盖；聊天登出仅等待状态事件，不制造另一条错误。
        #expect(conversation.loadError?.contains("resource_conflict") == true)
    }

    @Test func loggedOutStatusInEmailDoesNotRequestQRAndReturningStartsIt() async throws {
        LocalBackend.reset()
        let messages = MessagesState(connection: connection(), notifications: NotificationRecorder())
        var module = AppModule.email
        messages.viewingContext = {
            ViewingContext(activeModule: module, isAppActive: true, isWindowVisible: true, selectedChatID: nil)
        }
        messages.handle(.status(BackendStatus(state: .loggedOut)))
        #expect(messages.login.phase == .idle)
        #expect(LocalBackend.count("/login/qr") == 0)
        module = .messages
        messages.updateLoginVisibility()
        try await waitUntil { LocalBackend.count("/login/qr") == 1 }
        module = .email
        messages.updateLoginVisibility()
        #expect(messages.login.phase == .idle)
        messages.login.end()
    }

    @Test func appRestoresModuleAndRoutesBeforeOpeningTarget() {
        _ = NSApplication.shared
        let suite = "phase-b-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("email", forKey: "active-module")
        let config = BackendConfig(uvPath: "", backendDir: "", externalEndpoint: nil, homeOverride: nil)
        let windows = WindowRecorder()
        let app = AppState(supervisor: BackendSupervisor(config: config), notifications: NotificationService(badgeWriter: { _ in }, notificationCenter: NotificationCenterRecorder()),
                           windows: windows, preferences: preferences)
        #expect(app.activeModule == .email)
        let mail = NotificationRoute.email(accountID: "test-account", folderID: "INBOX", messageID: "test-mail")
        app.open(mail)
        #expect(app.activeModule == .email)
        #expect(app.pendingMailRoute == mail)
        let chat = try! #require(NotificationRoute(userInfo: NotificationRoute.messages(chatID: "chat").userInfo))
        app.open(chat)
        #expect(app.activeModule == .messages)
        #expect(windows.shown == 2)
        #expect(preferences.string(forKey: "active-module") == "messages")
        #expect(app.messages.login.phase == .idle)
    }
}
