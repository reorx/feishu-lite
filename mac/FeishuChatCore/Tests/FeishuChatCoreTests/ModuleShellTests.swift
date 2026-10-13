import Foundation
import Testing
@testable import FeishuChatCore

private func viewing(_ module: AppModule = .email, active: Bool = true, visible: Bool = true) -> ViewingContext {
    ViewingContext(activeModule: module, isAppActive: active, isWindowVisible: visible,
                   selectedChatID: "chat", selectedMail: .email(accountID: "account", folderID: "INBOX", messageID: "mail"))
}

@Test func emailDoesNotReadOrSuppressThePreviouslySelectedChat() {
    let context = viewing()
    let chat = Chat(id: "chat", name: "测试群", type: .group, unread: 2, muted: false,
                    lastMessagePreview: "", lastMessageTime: 0)
    let message = Message(id: "message", chatID: "chat", position: 1, senderID: "sender", senderName: "测试",
                          isSelf: false, createTime: 0, type: "text", text: "测试消息", badged: true)
    #expect(!context.shouldMarkChatRead(chatID: "chat", hasLoaded: true, unread: 2, onlyIfUnread: false))
    #expect(context.viewingChatID == nil)
    #expect(NotificationPolicy.shouldNotify(message: message, chat: chat, context: context.notificationContext))
}

@Test func returningToMessagesReadsLoadedUnreadSelection() {
    #expect(viewing(.messages).shouldMarkChatRead(chatID: "chat", hasLoaded: true, unread: 2, onlyIfUnread: true))
    #expect(!viewing(.messages).shouldMarkChatRead(chatID: "other", hasLoaded: true, unread: 2, onlyIfUnread: true))
    #expect(!viewing(.messages).shouldMarkChatRead(chatID: "chat", hasLoaded: false, unread: 2, onlyIfUnread: true))
    #expect(!viewing(.messages).shouldMarkChatRead(chatID: "chat", hasLoaded: true, unread: 0, onlyIfUnread: true))
}

@Test(arguments: [AppModule.messages, .email])
func readingRequiresActiveAppAndVisibleWindow(module: AppModule) {
    #expect(viewing(module, active: false).viewingChatID == nil)
    #expect(viewing(module, visible: false).viewingChatID == nil)
    #expect(viewing(module, active: false).viewingMail == nil)
    #expect(viewing(module, visible: false).viewingMail == nil)
}

@Test func mailReadingRequiresSuccessfulBodyAndCurrentSelection() {
    let route = NotificationRoute.email(accountID: "account", folderID: "INBOX", messageID: "mail")
    #expect(viewing().shouldMarkMailRead(route: route, bodyLoaded: true))
    #expect(!viewing().shouldMarkMailRead(route: route, bodyLoaded: false))
    #expect(!viewing(.messages).shouldMarkMailRead(route: route, bodyLoaded: true))
    #expect(!viewing().shouldMarkMailRead(route: .email(accountID: "old", folderID: "INBOX", messageID: "mail"), bodyLoaded: true))
    #expect(!viewing().shouldMarkMailRead(route: .email(accountID: "account", folderID: "INBOX", messageID: nil), bodyLoaded: true))
}

@Test func qrLoginBelongsOnlyToMessages() {
    #expect(AppModule.messages.shouldStartChatLogin(state: .loggedOut))
    #expect(!AppModule.email.shouldStartChatLogin(state: .loggedOut))
    #expect(!AppModule.messages.shouldStartChatLogin(state: .online))
    #expect(!AppModule.messages.shouldStartChatLogin(state: nil))
}

@Test(arguments: [NotificationRoute.messages(chatID: "chat/中文"),
                  .email(accountID: "account", folderID: "收件箱/层级", messageID: "opaque-id"),
                  .email(accountID: "account", folderID: "INBOX", messageID: nil)])
func routesRoundTripAndChooseTheirModule(route: NotificationRoute) throws {
    let restored = try #require(NotificationRoute(userInfo: route.userInfo))
    #expect(restored == route)
    #expect(restored.module == (route.userInfo["domain"] == "messages" ? .messages : .email))
}

@Test func routesRejectMalformedTargetsAndSupportDeliveredLegacyChats() {
    #expect(NotificationRoute(userInfo: ["chat_id": "chat"]) == .messages(chatID: "chat"))
    #expect(NotificationRoute(userInfo: ["domain": "email", "chat_id": "chat"]) == nil)
    #expect(NotificationRoute(userInfo: ["domain": "messages", "chat_id": ""]) == nil)
    #expect(NotificationRoute(userInfo: ["domain": "unknown", "chat_id": "chat"]) == nil)
    #expect(NotificationRoute(userInfo: [:]) == nil)
    #expect(NotificationRoute.messages(chatID: "x").threadIdentifier != NotificationRoute.email(accountID: "x", folderID: "INBOX", messageID: nil).threadIdentifier)
    #expect(NotificationRoute.messages(chatID: "x").notificationIdentifier(itemID: "same") != NotificationRoute.email(accountID: "x", folderID: "INBOX", messageID: "same").notificationIdentifier(itemID: "same"))
}

@Test func badgeCombinesRealCountsAndFormatsZeroAndOverflow() {
    #expect(UnreadCounts(messages: 0, email: 0).badgeLabel == nil)
    #expect(UnreadCounts(messages: 12, email: 3).total == 15)
    #expect(UnreadCounts(messages: 12, email: 3).badgeLabel == "15")
    #expect(UnreadCounts(messages: 90, email: 9).badgeLabel == "99")
    #expect(UnreadCounts(messages: 90, email: 10).badgeLabel == "99+")
    #expect(UnreadCounts(messages: 123, email: 234).total == 357)
    #expect(UnreadCounts(messages: -1, email: 2).total == 2)
}

@Test func statusAcceptsLegacyBackendAndAdvertisedFeatures() throws {
    let legacy = try BackendJSON.decoder.decode(BackendStatus.self, from: Data(#"{"state":"logged_out","user":null,"last_error":null}"#.utf8))
    #expect(legacy.features.isEmpty)
    let modern = try BackendJSON.decoder.decode(BackendStatus.self, from: Data(#"{"state":"online","features":["mail"]}"#.utf8))
    #expect(modern.features == ["mail"])
    #expect(try BackendJSON.decoder.decode(BackendStatus.self, from: BackendJSON.encoder.encode(modern)) == modern)
}

@Test func onlyExplicitLoggedOutConflictMapsToChatLogout() {
    #expect(BackendError.responseError(status: 409, body: Data(#"{"detail":"logged_out"}"#.utf8)) == .loggedOut)
    for body in [#"{"detail":"conflict"}"#, #"{"domain":"mail","code":"auth_failed"}"#, #"{"detail":{"code":"logged_out"}}"#, "", "not-json"] {
        guard case .http(status: 409, detail: _) = BackendError.responseError(status: 409, body: Data(body.utf8)) else {
            Issue.record("非聊天冲突被误判为登出")
            continue
        }
    }
    #expect(BackendError.responseError(status: 200, body: Data()) == nil)
    guard case .http(status: 401, detail: _) = BackendError.responseError(status: 401, body: Data(#"{"detail":"logged_out"}"#.utf8)) else {
        Issue.record("非 409 被误判为聊天登出")
        return
    }
}
