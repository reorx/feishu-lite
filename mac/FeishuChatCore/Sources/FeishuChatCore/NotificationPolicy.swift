public struct NotificationContext: Equatable, Sendable {
    /// 用户此刻正看着的会话：App 在前台、窗口可见、并且选中了它
    public var viewingChatID: String?

    public init(viewingChatID: String?) {
        self.viewingChatID = viewingChatID
    }

    public init(isAppActive: Bool, isWindowVisible: Bool, selectedChatID: String?) {
        self.viewingChatID = isAppActive && isWindowVisible ? selectedChatID : nil
    }
}

public struct NotificationContent: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public enum NotificationPolicy {
    public static let maxBodyLength = 300
    public static let fallbackTitle = "飞书"

    public static func shouldNotify(message: Message, chat: Chat, context: NotificationContext) -> Bool {
        if message.isSelf || !message.badged || chat.muted {
            return false
        }
        return context.viewingChatID != message.chatID
    }

    public static func content(message: Message, chat: Chat) -> NotificationContent {
        let title = [chat.name, chat.type == .p2p ? message.senderName : "", fallbackTitle].first { !$0.isEmpty }!
        var body = message.text
        if chat.type == .group, !message.senderName.isEmpty, !message.isSystem {
            body = "\(message.senderName): \(body)"
        }
        if body.count > maxBodyLength {
            body = body.prefix(maxBodyLength - 1) + "…"
        }
        return NotificationContent(title: title, body: body)
    }
}
