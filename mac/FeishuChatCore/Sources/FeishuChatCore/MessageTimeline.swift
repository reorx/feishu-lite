/// 一个会话里已加载的消息：按 position 正序，按 id 去重。
/// 同一条消息可能来自历史接口、发送接口的响应和 SSE 推送，合并后只留一份。
public struct MessageTimeline: Equatable, Sendable {
    public private(set) var messages: [Message] = []

    public init() {}

    public var isEmpty: Bool { messages.isEmpty }
    public var oldestPosition: Int? { messages.first?.position }
    public var latestPosition: Int? { messages.last?.position }

    /// 返回内容是否有变化
    @discardableResult
    public mutating func merge(_ incoming: [Message]) -> Bool {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var changed = false
        for message in incoming where byID[message.id] != message {
            byID[message.id] = message
            changed = true
        }
        guard changed else { return false }
        messages = byID.values.sorted {
            ($0.position, $0.createTime, $0.id) < ($1.position, $1.createTime, $1.id)
        }
        return true
    }
}

/// 往上翻历史的游标。后端按 position 区间取消息，区间里的消息可能全被撤回或不可见，
/// 所以游标按区间推进，不依赖上一页实际返回了几条。
public struct HistoryCursor: Equatable, Sendable {
    public let pageSize: Int
    /// 下一页请求的 before_position
    public private(set) var before: Int

    public var hasMore: Bool { before > 0 }

    /// 首页（最新一页）加载完之后的状态；lastPosition 是首页覆盖到的最大 position
    public init(lastPosition: Int, pageSize: Int) {
        self.pageSize = pageSize
        self.before = max(0, lastPosition - pageSize + 1)
    }

    public mutating func advance() {
        before = max(0, before - pageSize)
    }
}

extension MessageTimeline {
    /// 合并重新拉到的最新一页。和已加载的消息接不上时（中间隔着没加载的消息），丢掉旧的只留这一页，
    /// 保证时间线里没有洞，往上翻还能从这一页接着翻。
    public mutating func mergeLatestPage(_ page: [Message]) {
        guard let pageOldest = page.map(\.position).min() else { return }
        if let latest = latestPosition, pageOldest > latest + 1 {
            messages = []
        }
        merge(page)
    }
}

/// 消息列表里的一行：同一个人连续发的消息只在第一条显示名字，隔了一段时间才再显示时间
public struct MessageRow: Identifiable, Equatable, Sendable {
    public static let timestampGap = 5 * 60

    public var message: Message
    public var showsTimestamp: Bool
    public var showsSender: Bool

    public var id: String { message.id }

    public static func rows(for messages: [Message], chatType: ChatType) -> [MessageRow] {
        var rows: [MessageRow] = []
        rows.reserveCapacity(messages.count)
        var previous: Message?
        for message in messages {
            let showsTimestamp = previous.map { message.createTime - $0.createTime > timestampGap } ?? true
            let startsGroup = showsTimestamp || previous?.senderID != message.senderID || previous?.isSystem == true
            let namedSender = chatType == .group && !message.isSelf && !message.isSystem
            rows.append(MessageRow(message: message, showsTimestamp: showsTimestamp,
                                   showsSender: namedSender && startsGroup))
            previous = message
        }
        return rows
    }
}
