import Foundation

public enum AppModule: String, CaseIterable, Sendable {
    case messages, email

    public func shouldStartChatLogin(state: ConnectionState?) -> Bool {
        self == .messages && state == .loggedOut
    }
}

/// 已读和通知共用的可见性快照；模块切换不清除另一个模块的选择。
public struct ViewingContext: Equatable, Sendable {
    public var activeModule: AppModule
    public var isAppActive: Bool
    public var isWindowVisible: Bool
    public var selectedChatID: String?
    public var selectedMail: NotificationRoute?

    public init(activeModule: AppModule, isAppActive: Bool, isWindowVisible: Bool,
                selectedChatID: String?, selectedMail: NotificationRoute? = nil) {
        self.activeModule = activeModule
        self.isAppActive = isAppActive
        self.isWindowVisible = isWindowVisible
        self.selectedChatID = selectedChatID
        self.selectedMail = selectedMail
    }

    public var viewingChatID: String? {
        activeModule == .messages && isAppActive && isWindowVisible ? selectedChatID : nil
    }

    public var viewingMail: NotificationRoute? {
        guard activeModule == .email, isAppActive, isWindowVisible,
              case .email(_, _, .some) = selectedMail else { return nil }
        return selectedMail
    }

    public var notificationContext: NotificationContext { NotificationContext(viewingChatID: viewingChatID) }

    public func shouldMarkChatRead(chatID: String, hasLoaded: Bool, unread: Int, onlyIfUnread: Bool) -> Bool {
        viewingChatID == chatID && hasLoaded && (!onlyIfUnread || unread > 0)
    }

    public func shouldMarkMailRead(route: NotificationRoute, bodyLoaded: Bool) -> Bool {
        bodyLoaded && viewingMail == route
    }
}

public struct UnreadCounts: Equatable, Sendable {
    public var messages: Int
    public var email: Int
    public var total: Int { max(0, messages) + max(0, email) }
    public var badgeLabel: String? { Self.label(for: total) }

    public init(messages: Int, email: Int) {
        self.messages = messages
        self.email = email
    }

    public static func label(for count: Int) -> String? {
        count <= 0 ? nil : count > 99 ? "99+" : String(count)
    }
}

/// 单封邮件用完整账号/文件夹/邮件目标；messageID 为 nil 表示收件箱汇总通知。
public enum NotificationRoute: Equatable, Sendable {
    case messages(chatID: String)
    case email(accountID: String, folderID: String, messageID: String?)

    public var module: AppModule {
        switch self {
        case .messages: .messages
        case .email: .email
        }
    }

    public var userInfo: [String: String] {
        switch self {
        case let .messages(chatID):
            ["domain": "messages", "chat_id": chatID]
        case let .email(accountID, folderID, messageID):
            ["domain": "email", "mail_account_id": accountID, "folder_id": folderID]
                .merging(messageID.map { ["message_id": $0] } ?? [:]) { _, new in new }
        }
    }

    public init?(userInfo: [AnyHashable: Any]) {
        let domain = userInfo["domain"] as? String
        switch domain {
        case "messages", nil:
            guard let id = userInfo["chat_id"] as? String, !id.isEmpty else { return nil }
            self = .messages(chatID: id)
        case "email":
            guard let account = userInfo["mail_account_id"] as? String, !account.isEmpty,
                  let folder = userInfo["folder_id"] as? String, !folder.isEmpty else { return nil }
            let message = userInfo["message_id"] as? String
            if userInfo["message_id"] != nil, message == nil || message!.isEmpty { return nil }
            self = .email(accountID: account, folderID: folder, messageID: message)
        default:
            return nil
        }
    }

    public var threadIdentifier: String {
        switch self {
        case let .messages(chatID): "messages:" + Self.component(chatID)
        case let .email(accountID, folderID, _): "email:" + Self.component(accountID) + ":" + Self.component(folderID)
        }
    }

    public func notificationIdentifier(itemID: String) -> String {
        threadIdentifier + ":" + Self.component(itemID)
    }

    private static func component(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}
