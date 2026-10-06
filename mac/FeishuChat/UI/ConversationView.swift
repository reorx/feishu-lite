import FeishuChatCore
import SwiftUI

struct ConversationView: View {
    let conversation: Conversation
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(conversation: conversation)
            Divider()
            ComposerView(conversation: conversation)
        }
        .navigationTitle(title)
    }
}

private struct MessageListView: View {
    let conversation: Conversation

    var body: some View {
        // 首页加载完再渲染列表：内容在列表出现之后才到的话，初始位置会停在最上面而不是最新消息
        if conversation.hasLoaded, !conversation.rows.isEmpty {
            MessageScrollView(conversation: conversation)
        } else {
            EmptyStateView(conversation: conversation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MessageScrollView: View {
    let conversation: Conversation

    private static let bottomID = "bottom"
    @State private var isAtBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    HistoryHeader(conversation: conversation)
                    ForEach(conversation.rows) { row in
                        MessageRowView(row: row, conversation: conversation)
                            .id(row.id)
                    }
                    Color.clear
                        .frame(height: 8)
                        .id(Self.bottomID)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.horizontal, 16)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation.latestMessageID) {
                // 正在翻历史时不打断；停在底部时跟着新消息走
                if isAtBottom {
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

/// 消息列表最上面的一行：滚到这里就加载更早的消息
private struct HistoryHeader: View {
    let conversation: Conversation

    var body: some View {
        Group {
            if conversation.hasOlder {
                ProgressView()
                    .controlSize(.small)
                    .onAppear {
                        Task { await conversation.loadOlder() }
                    }
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

    var body: some View {
        if let error = conversation.loadError {
            ContentUnavailableView("加载失败", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if conversation.hasLoaded {
            Text("还没有消息")
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
        }
    }
}

private struct MessageRowView: View {
    let row: MessageRow
    let conversation: Conversation

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
                MessageBubbleView(message: row.message, showsSender: row.showsSender, conversation: conversation)
                    .padding(.top, row.showsSender ? 10 : 3)
            }
        }
    }
}

private struct MessageBubbleView: View {
    let message: Message
    let showsSender: Bool
    let conversation: Conversation

    @Environment(\.today) private var today

    var body: some View {
        HStack(spacing: 0) {
            if message.isSelf {
                Spacer(minLength: 80)
            }
            VStack(alignment: .leading, spacing: 3) {
                if showsSender {
                    Text(message.senderName.isEmpty ? "未知用户" : message.senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                if message.isViewableImage {
                    ImageMessageView(messageID: message.id, conversation: conversation)
                } else {
                    Text(MessageText.attributed(message.text))
                        .textSelection(.enabled)
                        .foregroundStyle(message.isSelf ? Color.white : Color.primary)
                        .tint(message.isSelf ? Color.white : Color.accentColor)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(message.isSelf ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                    in: .rect(cornerRadius: 12))
                        .help(ChatTimeFormat.messageLabel(message.createTime, now: today))
                }
            }
            if !message.isSelf {
                Spacer(minLength: 80)
            }
        }
        .accessibilityElement(children: .combine)
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
