import FeishuChatCore
import Foundation
import os

/// 当前打开的会话：已加载的消息、往上翻页的进度、输入框草稿和发送状态
@MainActor
@Observable
final class Conversation {
    /// 连续翻到空页（区间里的消息都不可见）时最多再往前试几页
    static let maxEmptyPages = 5

    let chatID: String
    let chatType: ChatType

    private(set) var rows: [MessageRow] = []
    /// 首页是否已经加载过
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isLoadingOlder = false
    private(set) var hasOlder = false
    private(set) var loadError: String?
    private(set) var isSending = false
    private(set) var sendError: String?
    /// 每翻出更早的一页就换一个值：翻之前最上面那条消息的 id，视图用它保持滚动位置
    private(set) var prependAnchor: PrependAnchor?
    var draft: String

    struct PrependAnchor: Equatable {
        var messageID: String
        var serial: Int
    }

    // 从 rows 取而不是从 timeline 取：timeline 不参与观察，视图依赖它的话收不到变化
    var latestPosition: Int? { rows.last?.message.position }
    var latestMessageID: String? { rows.last?.id }

    @ObservationIgnored private var timeline = MessageTimeline() {
        didSet { rows = MessageRow.rows(for: timeline.messages, chatType: chatType) }
    }
    @ObservationIgnored private var cursor: HistoryCursor?
    @ObservationIgnored private var prependSerial = 0
    @ObservationIgnored private let connection: BackendConnection
    @ObservationIgnored private let log = Logger(subsystem: "com.reorx.FeishuChat", category: "conversation")

    init(chat: Chat, draft: String, connection: BackendConnection) {
        chatID = chat.id
        chatType = chat.type
        self.draft = draft
        self.connection = connection
    }

    /// 拉最新一页。首次打开、事件流重连、发现服务端有更新的消息时调用。
    func loadLatest(chatLastPosition: Int) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await connection.requireClient().messages(chatID: chatID)
            let hadGap = timeline.latestPosition.map { latest in
                page.first.map { $0.position > latest + 1 } ?? false
            } ?? false
            timeline.mergeLatestPage(page)
            if cursor == nil || hadGap {
                let top = page.last?.position ?? chatLastPosition
                cursor = HistoryCursor(lastPosition: top, pageSize: BackendClient.pageSize)
                hasOlder = cursor?.hasMore ?? false
            }
            hasLoaded = true
            loadError = nil
        } catch {
            report(error, as: \.loadError, prefix: "加载消息失败")
        }
    }

    /// 往上翻一页
    func loadOlder() async {
        guard var cursor, cursor.hasMore, !isLoadingOlder, !isLoading else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let anchorID = timeline.messages.first?.id
        do {
            let client = try connection.requireClient()
            for _ in 0..<Self.maxEmptyPages where cursor.hasMore {
                let page = try await client.messages(chatID: chatID, before: cursor.before)
                cursor.advance()
                if timeline.merge(page) { break }
            }
            self.cursor = cursor
            hasOlder = cursor.hasMore
            loadError = nil
            if let anchorID, timeline.messages.first?.id != anchorID {
                prependSerial += 1
                prependAnchor = PrependAnchor(messageID: anchorID, serial: prependSerial)
            }
        } catch {
            report(error, as: \.loadError, prefix: "加载更早的消息失败")
        }
    }

    /// 实时推送来的消息，或者发送接口返回的消息；重复的会被合并掉
    func receive(_ message: Message) {
        guard message.chatID == chatID, hasLoaded else { return }
        timeline.merge([message])
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }
        let original = draft
        draft = ""
        do {
            let sent = try await connection.requireClient().send(chatID: chatID, text: text)
            sendError = nil
            timeline.merge([sent])
        } catch {
            if draft.isEmpty {
                draft = original
            }
            report(error, as: \.sendError, prefix: "发送失败")
        }
    }

    func dismissSendError() {
        sendError = nil
    }

    private func report(_ error: any Error, as keyPath: ReferenceWritableKeyPath<Conversation, String?>, prefix: String) {
        // 凭证失效时后端会推 logged_out，界面整个切到登录页，这里不用再报
        if case BackendError.loggedOut = error { return }
        if error is CancellationError { return }
        log.error("\(prefix, privacy: .public): \(error.localizedDescription, privacy: .public)")
        self[keyPath: keyPath] = "\(prefix)：\(error.localizedDescription)"
    }
}
