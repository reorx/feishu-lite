import Testing
@testable import FeishuChatCore

private func chat(_ id: String = "c1", name: String = "项目群", type: ChatType = .group, muted: Bool = false) -> Chat {
    Chat(id: id, name: name, type: type, unread: 1, muted: muted, lastMessagePreview: "", lastMessageTime: 0)
}

private func message(chat: String = "c1", sender: String = "张三", text: String = "你好", isSelf: Bool = false,
                     type: String = "text", badged: Bool = true) -> Message {
    Message(id: "m1", chatID: chat, position: 1, senderID: "u1", senderName: sender, isSelf: isSelf,
            createTime: 100, type: type, text: text, badged: badged)
}

private let background = NotificationContext(viewingChatID: nil)

@Test func notifiesForIncomingMessage() {
    #expect(NotificationPolicy.shouldNotify(message: message(), chat: chat(), context: background))
}

@Test func doesNotNotifyForOwnMessage() {
    #expect(!NotificationPolicy.shouldNotify(message: message(isSelf: true), chat: chat(), context: background))
}

@Test func doesNotNotifyForMutedChat() {
    #expect(!NotificationPolicy.shouldNotify(message: message(), chat: chat(muted: true), context: background))
}

@Test func doesNotNotifyWhenTheChatIsBeingViewed() {
    let viewing = NotificationContext(viewingChatID: "c1")
    #expect(!NotificationPolicy.shouldNotify(message: message(), chat: chat(), context: viewing))
}

@Test func notifiesWhenAnotherChatIsBeingViewed() {
    let viewing = NotificationContext(viewingChatID: "c2")
    #expect(NotificationPolicy.shouldNotify(message: message(), chat: chat(), context: viewing))
}

@Test func viewingRequiresActiveAppVisibleWindowAndSelection() {
    #expect(NotificationContext(isAppActive: true, isWindowVisible: true, selectedChatID: "c1").viewingChatID == "c1")
    #expect(NotificationContext(isAppActive: false, isWindowVisible: true, selectedChatID: "c1").viewingChatID == nil)
    #expect(NotificationContext(isAppActive: true, isWindowVisible: false, selectedChatID: "c1").viewingChatID == nil)
    #expect(NotificationContext(isAppActive: true, isWindowVisible: true, selectedChatID: nil).viewingChatID == nil)
}

@Test func doesNotNotifyForMessagesThatDoNotCountAsUnread() {
    // 系统消息（"xx 加入群聊"）不计未读，也不该打扰
    let system = message(sender: "系统消息", type: "system", badged: false)
    #expect(!NotificationPolicy.shouldNotify(message: system, chat: chat(), context: background))
}

@Test func groupNotificationPrefixesSender() {
    let content = NotificationPolicy.content(message: message(sender: "张三", text: "明天开会"), chat: chat(name: "项目群"))
    #expect(content == NotificationContent(title: "项目群", body: "张三: 明天开会"))
}

@Test func directNotificationShowsTextOnly() {
    let content = NotificationPolicy.content(
        message: message(sender: "李四", text: "在吗"), chat: chat(name: "李四", type: .p2p))
    #expect(content == NotificationContent(title: "李四", body: "在吗"))
}

@Test func notificationFallsBackWhenNamesAreMissing() {
    let unnamedGroup = NotificationPolicy.content(message: message(sender: "", text: "hi"), chat: chat(name: ""))
    #expect(unnamedGroup == NotificationContent(title: "飞书", body: "hi"))

    let unnamedDirect = NotificationPolicy.content(
        message: message(sender: "李四", text: "hi"), chat: chat(name: "", type: .p2p))
    #expect(unnamedDirect.title == "李四")
}

@Test func longNotificationBodyIsTruncated() {
    let content = NotificationPolicy.content(
        message: message(text: String(repeating: "长", count: 1000)), chat: chat(type: .p2p))
    #expect(content.body.count == NotificationPolicy.maxBodyLength)
    #expect(content.body.hasSuffix("…"))
}
