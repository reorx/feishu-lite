import FeishuLiteCore
import SwiftUI

struct ConversationView: View {
    let conversation: Conversation
    let title: String
    let messages: MessagesState

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(conversation: conversation, messages: messages)
            Divider()
            ComposerView(conversation: conversation)
        }
        .navigationTitle(title)
    }
}

private struct MessageListView: View {
    let conversation: Conversation
    let messages: MessagesState

    var body: some View {
        // 首页加载完再渲染列表：内容在列表出现之后才到的话，初始位置会停在最上面而不是最新消息
        if conversation.hasLoaded, !conversation.rows.isEmpty {
            MessageScrollView(conversation: conversation, messages: messages)
        } else {
            EmptyStateView(conversation: conversation, messages: messages)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MessageScrollView: View {
    let conversation: Conversation
    let messages: MessagesState

    private static let bottomID = "bottom"
    private static let historyID = "history"
    @State private var isAtBottom = true
    @State private var isRestoringScroll = true
    @State private var historyIsVisible = false
    @State private var visibleImageIDs: Set<String> = []

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // 预览关闭后再缩放窗口，LazyVStack 的可变高度消息布局可能无法收敛。
                    // 对已加载的消息确定布局，避免估算尺寸和原生文本失效反复互相触发。
                    VStack(spacing: 0) {
                        HistoryHeader(conversation: conversation)
                            .trackScrollRow(Self.historyID, space: "message-list")
                        let bubbleWidth = MessageBubbleView.maxWidth(forListWidth: viewport.size.width - 32)
                        ForEach(conversation.rows) { row in
                            MessageRowView(row: row, conversation: conversation, isImageVisible: visibleImageIDs.contains(row.id),
                                           maxBubbleWidth: bubbleWidth)
                                .id(row.id)
                                .trackScrollRow(row.id, space: "message-list")
                        }
                        Color.clear
                            .frame(height: 8)
                            .id(Self.bottomID)
                            .trackScrollRow(Self.bottomID, space: "message-list")
                    }
                    .padding(.horizontal, 16)
                }
                .defaultScrollAnchor(.bottom)
                .coordinateSpace(name: "message-list")
                .onPreferenceChange(VisibleScrollRows.self) { frames in
                    // 普通栈确定所有行的尺寸，但图片仍只在进入 viewport 时下载。
                    let imageIDs = Set(conversation.rows.lazy.filter { $0.message.isViewableImage }.map(\.id))
                    let visibleImages = Set(frames.compactMap { id, frame in
                        imageIDs.contains(id) && frame.maxY > 0 && frame.minY < viewport.size.height ? id : nil
                    })
                    if visibleImageIDs != visibleImages { visibleImageIDs = visibleImages }
                    guard !isRestoringScroll else { return }
                    let historyVisible = frames[Self.historyID].map {
                        $0.maxY > 0 && $0.minY < viewport.size.height
                    } ?? false
                    if historyIsVisible != historyVisible { historyIsVisible = historyVisible }
                    let atBottom = frames[Self.bottomID].map {
                        $0.minY >= 0 && $0.maxY <= viewport.size.height + 1
                    } ?? false
                    if isAtBottom != atBottom { isAtBottom = atBottom }
                    if isAtBottom {
                        if messages.detailScrollAnchors[conversation.chatID] != Self.bottomID {
                            messages.detailScrollAnchors[conversation.chatID] = Self.bottomID
                        }
                    } else if let id = VisibleScrollRows.first(in: frames.filter { $0.key != Self.bottomID && $0.key != Self.historyID },
                                                             height: viewport.size.height),
                              messages.detailScrollAnchors[conversation.chatID] != id {
                        messages.detailScrollAnchors[conversation.chatID] = id
                    }
                }
                .task(id: historyIsVisible) {
                    if historyIsVisible { await conversation.loadOlder() }
                }
                .task {
                    let anchor = messages.detailScrollAnchors[conversation.chatID] ?? Self.bottomID
                    isAtBottom = anchor == Self.bottomID
                    await Task.yield()
                    proxy.scrollTo(anchor, anchor: isAtBottom ? .bottom : .top)
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    isRestoringScroll = false
                }
                .onChange(of: conversation.latestMessageID) {
                    // 正在翻历史时不打断；停在底部时跟着新消息走
                    if isAtBottom, !isRestoringScroll {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: conversation.prependAnchor) { _, anchor in
                    guard let anchor else { return }
                    // 刚打开会话时，首次布局会短暂渲染出顶部的加载行，触发一次翻页；这时用户还停在底部，
                    // 要留在最新消息那里，不能跳到翻页前的第一条
                    if isAtBottom {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    } else {
                        // 用户往上翻出了更早的一页：回到翻页之前最上面的那条消息
                        proxy.scrollTo(anchor.messageID, anchor: .top)
                    }
                }
            }
        }
    }
}

/// 消息列表最上面的一行：滚到这里就加载更早的消息；失败时显示原因和重试
private struct HistoryHeader: View {
    let conversation: Conversation

    var body: some View {
        Group {
            if let error = conversation.olderLoadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(error)
                        .foregroundStyle(.secondary)
                    Button("重试") {
                        Task { await conversation.loadOlder() }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                .font(.caption)
            } else if conversation.hasOlder {
                ProgressView()
                    .controlSize(.small)
            } else if conversation.hasLoaded, !conversation.rows.isEmpty {
                Text("没有更早的消息了")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

private struct EmptyStateView: View {
    let conversation: Conversation
    let messages: MessagesState

    var body: some View {
        if let error = conversation.loadError {
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试") {
                    Task { await messages.retryConversation() }
                }
                .disabled(conversation.isLoading)
            }
        } else if conversation.hasLoaded {
            ContentUnavailableView("还没有消息", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("发出的第一条消息会显示在这里"))
        } else {
            ProgressView()
        }
    }
}

private struct MessageRowView: View {
    let row: MessageRow
    let conversation: Conversation
    let isImageVisible: Bool
    let maxBubbleWidth: CGFloat

    @Environment(\.today) private var today

    var body: some View {
        VStack(spacing: 0) {
            if row.showsTimestamp {
                Text(ChatTimeFormat.messageLabel(row.message.createTime, now: today))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
            }
            if row.message.isSystem {
                Text(row.message.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
            } else {
                MessageBubbleView(message: row.message, showsSender: row.showsSender, conversation: conversation,
                                  isImageVisible: isImageVisible, maxWidth: maxBubbleWidth)
                    .padding(.top, row.showsSender ? 10 : 3)
            }
        }
    }
}

private struct MessageBubbleView: View {
    let message: Message
    let showsSender: Bool
    let conversation: Conversation
    let isImageVisible: Bool
    let maxWidth: CGFloat

    @Environment(\.today) private var today

    /// 气泡最多占消息区宽度的 70%，宽窗口下再封顶，长消息不会拉成一整行
    static func maxWidth(forListWidth width: CGFloat) -> CGFloat {
        min(560, max(240, width * 0.7))
    }

    var body: some View {
        let meeting = message.meetingInvitation
        HStack(spacing: 0) {
            if message.isSelf {
                Spacer(minLength: 80)
            }
            VStack(alignment: message.isSelf ? .trailing : .leading, spacing: 3) {
                if showsSender {
                    // 和气泡的左边对齐
                    Text(message.senderName.isEmpty ? "未知用户" : message.senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if message.isViewableImage {
                    ImageMessageView(messageID: message.id, conversation: conversation, isVisible: isImageVisible)
                } else if let meeting {
                    MeetingCardView(meeting: meeting)
                        .frame(width: min(300, maxWidth))
                        .help(ChatTimeFormat.messageLabel(message.createTime, now: today))
                } else {
                    Text(MessageText.attributed(message.text))
                        .textSelection(.enabled)
                        .foregroundStyle(message.isSelf ? Color.white : Color.primary)
                        .tint(message.isSelf ? Color.white : Color.accentColor)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(message.isSelf ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                    in: .rect(cornerRadius: 12))
                        .frame(maxWidth: maxWidth, alignment: message.isSelf ? .trailing : .leading)
                        .help(ChatTimeFormat.messageLabel(message.createTime, now: today))
                }
            }
            if !message.isSelf {
                Spacer(minLength: 80)
            }
        }
        // 会议卡片里的“加入会议”要能单独操作，不和整行合并
        .accessibilityElement(children: meeting == nil ? .combine : .contain)
    }
}

/// 会议邀请卡片：图标、主题、会议号和“加入会议”。数据来自 Core 对后端会议文本的解析。
private struct MeetingCardView: View {
    let meeting: MeetingInvitation

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "video.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.teal.gradient, in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("视频会议")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(meeting.topic ?? "未命名会议")
                        .fontWeight(.semibold)
                        .foregroundStyle(meeting.topic == nil ? .secondary : .primary)
                        .lineLimit(4)
                }
            }
            Divider()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("会议号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(meeting.formattedNumber)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("加入会议") { openURL(meeting.joinURL) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(meeting.joinURL.absoluteString)
                    .fixedSize()
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视频会议邀请：\(meeting.topic ?? "未命名会议")，会议号 \(meeting.formattedNumber)")
    }
}

enum MessageText {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// 把正文里的网址变成可以点的链接
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard text.contains("://") || text.contains("www."), let linkDetector else { return result }
        let matches = linkDetector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }
}
