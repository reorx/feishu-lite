import Foundation

public enum MailConnectionState: String, Codable, Sendable {
    case unconfigured, connecting, online, offline
    case credentialMissing = "credential_missing"
    case authFailed = "auth_failed"
}

public struct MailAccount: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var address: String
}

public struct MailKey: Codable, Equatable, Sendable {
    public var accountID: String
    public var folderID: String
    public var uidvalidity: Int
    public var uid: Int
    enum CodingKeys: String, CodingKey {
        case accountID = "account_id", folderID = "folder_id", uidvalidity, uid
    }
}

public struct MailAddress: Codable, Equatable, Sendable {
    public var name: String
    public var address: String
}

public struct MailAttachment: Codable, Equatable, Sendable {
    public var section: String
    public var filename: String
    public var mediaType: String
    public var encodedSize: Int?
    public var sizeIsApproximate: Bool
    public var contentID: String?
    enum CodingKeys: String, CodingKey {
        case section, filename, mediaType = "media_type", encodedSize = "encoded_size"
        case sizeIsApproximate = "size_is_approximate", contentID = "content_id"
    }
}

public struct MailBodyPart: Codable, Equatable, Sendable {
    public var section: String
    public var mediaType: String
    public var params: [String: String]
    public var contentID: String?
    public var encoding: String
    public var encodedSize: Int
    public var disposition: String?
    public var filename: String
    public var children: [MailBodyPart]
    enum CodingKeys: String, CodingKey {
        case section, params, encoding, disposition, filename, children
        case mediaType = "media_type", contentID = "content_id", encodedSize = "encoded_size"
    }
}

public struct MailSummary: Codable, Equatable, Sendable, Identifiable {
    /// 后端交付的不透明 id；不在 App 中重编 MailKey。
    public var id: String
    public var key: MailKey
    public var subject: String
    public var sender: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var date: String
    public var messageID: String
    public var receivedAt: Int
    public var size: Int
    public var flags: [String]
    public var unread: Bool
    public var attachments: [MailAttachment]
    public var bodyPart: MailBodyPart?
    public var error: String?
    public var displaySubject: String { subject.isEmpty ? "（无主题）" : subject }
    public var displaySender: String {
        sender.map { $0.name.isEmpty ? $0.address : $0.name }.joined(separator: "、")
    }
    enum CodingKeys: String, CodingKey {
        case id, key, subject, sender, to, cc, date, size, flags, unread, attachments, error
        case messageID = "message_id", receivedAt = "received_at", bodyPart = "body_part"
    }
}

public struct MailFolder: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var delimiter: String?
    public var flags: [String]
    public var selectable: Bool
    public var supported: Bool
}

public struct MailPage: Codable, Equatable, Sendable {
    public var items: [MailSummary]
    public var nextCursor: String?
    enum CodingKeys: String, CodingKey { case items, nextCursor = "next_cursor" }
}

public struct MailBody: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case plain, html }
    public var kind: Kind
    public var content: String
}

public struct MailNotification: Codable, Equatable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable { case individual, summary }
    public var id: String
    public var accountID: String
    public var folderID: String
    public var uidvalidity: Int
    public var mode: Mode
    public var items: [MailSummary]
    enum CodingKeys: String, CodingKey {
        case id, uidvalidity, mode, items, accountID = "account_id", folderID = "folder_id"
    }
}

public struct MailStatus: Codable, Equatable, Sendable {
    public var mailAccountID: String?
    public var address: String?
    public var state: MailConnectionState
    public var generation: Int
    public var uidvalidity: Int?
    /// Unix 秒，保留 wire 整数；转换 Date 只用于展示。
    public var lastSyncAt: Int?
    public var unreadCount: Int
    public var unreadStale: Bool
    public var pending: [MailNotification]
    public var error: String?
    enum CodingKeys: String, CodingKey {
        case mailAccountID = "mail_account_id", address, state, generation, uidvalidity
        case lastSyncAt = "last_sync_at", unreadCount = "unread_count", unreadStale = "unread_stale", pending, error
    }
    public init(mailAccountID: String? = nil, address: String? = nil, state: MailConnectionState = .unconfigured,
                generation: Int = 0, uidvalidity: Int? = nil, lastSyncAt: Int? = nil,
                unreadCount: Int = 0, unreadStale: Bool = true, pending: [MailNotification] = [], error: String? = nil) {
        self.mailAccountID = mailAccountID; self.address = address; self.state = state; self.generation = generation
        self.uidvalidity = uidvalidity; self.lastSyncAt = lastSyncAt; self.unreadCount = unreadCount
        self.unreadStale = unreadStale; self.pending = pending; self.error = error
    }
}

public struct MailEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case status = "mail.status", updated = "mail.updated", arrived = "mail.arrived" }
    public var type: Kind
    public var accountID: String?
    public var generation: Int
    public var folderID: String
    public var uidvalidity: Int?
    public var status: MailStatus?
    public var notification: MailNotification?
    public var readIDs: [String]
    public var deletedIDs: [String]
    public var reset: Bool
    enum CodingKeys: String, CodingKey {
        case type, accountID = "account_id", generation, folderID = "folder_id", uidvalidity, status, notification
        case readIDs = "read_ids", deletedIDs = "deleted_ids", reset
    }
}

public struct MailAccountChange: Codable, Equatable, Sendable {
    public var account: MailAccount?
    public var removedAccountID: String?
    enum CodingKeys: String, CodingKey { case account, removedAccountID = "removed_account_id" }
}
public struct MailConnectionTest: Codable, Equatable, Sendable {
    public var writable: Bool
    public var supportsIdle: Bool
    enum CodingKeys: String, CodingKey { case writable, supportsIdle = "supports_idle" }
}
public struct MailReadResult: Codable, Equatable, Sendable {
    public var readIDs: [String]
    enum CodingKeys: String, CodingKey { case readIDs = "read_ids" }
}

/// 请求专用值；描述与反射不暴露密码，只有明确的请求编码/钥匙串存取能获取值。
public struct MailSecret: Encodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { "<redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public func withValue<T>(_ body: (String) throws -> T) rethrows -> T { try body(value) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
