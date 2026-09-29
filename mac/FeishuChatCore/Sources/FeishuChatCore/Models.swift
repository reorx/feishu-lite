import Foundation

// 后端 HTTP API 的数据模型，字段以 backend/src/feishu_lite/types.py 为准。

public enum ChatType: String, Codable, Sendable {
    case p2p
    case group
}

public enum ConnectionState: String, Codable, Sendable {
    case loggedOut = "logged_out"
    case connecting
    case online
    case reconnecting
}

public enum QRLoginStatus: String, Codable, Sendable {
    case idle, waiting, scanned, success, expired, failed
}

public struct User: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Chat: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: ChatType
    public var unread: Int
    public var muted: Bool
    public var lastMessagePreview: String
    /// unix 秒；0 表示会话里还没有消息
    public var lastMessageTime: Int
    public var lastPosition: Int
    /// 排序键，和服务端 feed 的顺序一致，越大越靠前
    public var rankTime: Int

    enum CodingKeys: String, CodingKey {
        case id, name, type, unread, muted
        case lastMessagePreview = "last_message_preview"
        case lastMessageTime = "last_message_time"
        case lastPosition = "last_position"
        case rankTime = "rank_time"
    }

    public init(id: String, name: String, type: ChatType, unread: Int, muted: Bool, lastMessagePreview: String,
                lastMessageTime: Int, lastPosition: Int = -1, rankTime: Int? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.unread = unread
        self.muted = muted
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageTime = lastMessageTime
        self.lastPosition = lastPosition
        self.rankTime = rankTime ?? lastMessageTime
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(ChatType.self, forKey: .type)
        unread = try c.decode(Int.self, forKey: .unread)
        muted = try c.decode(Bool.self, forKey: .muted)
        lastMessagePreview = try c.decode(String.self, forKey: .lastMessagePreview)
        lastMessageTime = try c.decode(Int.self, forKey: .lastMessageTime)
        lastPosition = try c.decodeIfPresent(Int.self, forKey: .lastPosition) ?? -1
        rankTime = try c.decodeIfPresent(Int.self, forKey: .rankTime) ?? lastMessageTime
    }
}

public struct Message: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var chatID: String
    public var position: Int
    public var senderID: String
    public var senderName: String
    public var isSelf: Bool
    /// unix 秒
    public var createTime: Int
    /// text / post / image / file / card / system / ...，没见过的类型原样保留
    public var type: String
    public var text: String
    /// 是否计入未读（系统消息不计）
    public var badged: Bool
    public var atMe: Bool

    public var isSystem: Bool { type == "system" }

    enum CodingKeys: String, CodingKey {
        case id, position, type, text, badged
        case chatID = "chat_id"
        case senderID = "sender_id"
        case senderName = "sender_name"
        case isSelf = "is_self"
        case createTime = "create_time"
        case atMe = "at_me"
    }

    public init(id: String, chatID: String, position: Int, senderID: String, senderName: String, isSelf: Bool,
                createTime: Int, type: String, text: String, badged: Bool = true, atMe: Bool = false) {
        self.id = id
        self.chatID = chatID
        self.position = position
        self.senderID = senderID
        self.senderName = senderName
        self.isSelf = isSelf
        self.createTime = createTime
        self.type = type
        self.text = text
        self.badged = badged
        self.atMe = atMe
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        chatID = try c.decode(String.self, forKey: .chatID)
        position = try c.decode(Int.self, forKey: .position)
        senderID = try c.decode(String.self, forKey: .senderID)
        senderName = try c.decode(String.self, forKey: .senderName)
        isSelf = try c.decode(Bool.self, forKey: .isSelf)
        createTime = try c.decode(Int.self, forKey: .createTime)
        type = try c.decode(String.self, forKey: .type)
        text = try c.decode(String.self, forKey: .text)
        badged = try c.decodeIfPresent(Bool.self, forKey: .badged) ?? true
        atMe = try c.decodeIfPresent(Bool.self, forKey: .atMe) ?? false
    }
}

public struct BackendStatus: Codable, Equatable, Sendable {
    public var state: ConnectionState
    public var user: User?
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case state, user
        case lastError = "last_error"
    }

    public init(state: ConnectionState, user: User? = nil, lastError: String? = nil) {
        self.state = state
        self.user = user
        self.lastError = lastError
    }
}

public struct QRLoginStart: Codable, Equatable, Sendable {
    public var qrContent: String

    enum CodingKeys: String, CodingKey {
        case qrContent = "qr_content"
    }
}

public struct QRLoginPoll: Codable, Equatable, Sendable {
    public var status: QRLoginStatus
}

public struct SendMessageBody: Codable, Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public enum BackendJSON {
    public static var decoder: JSONDecoder { JSONDecoder() }
    public static var encoder: JSONEncoder { JSONEncoder() }
}
