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
