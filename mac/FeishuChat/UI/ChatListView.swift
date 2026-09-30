import FeishuChatCore
import SwiftUI

struct ChatListView: View {
    let chats: [Chat]
    @Binding var selection: String?

    var body: some View {
        List(chats, selection: $selection) { chat in
            ChatRowView(chat: chat)
        }
        .overlay {
            if chats.isEmpty {
                Text("还没有会话")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChatRowView: View {
    let chat: Chat

    @Environment(\.today) private var today

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: chat.displayName, seed: chat.id, isGroup: chat.type == .group)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(chat.displayName)
                        .fontWeight(chat.unread > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    if chat.muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("免打扰")
                    }
                    Spacer(minLength: 4)
                    Text(ChatTimeFormat.listLabel(chat.lastMessageTime, now: today))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(chat.lastMessagePreview.isEmpty ? " " : chat.lastMessagePreview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if chat.unread > 0 {
                        UnreadBadge(count: chat.unread, muted: chat.muted)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct UnreadBadge: View {
    let count: Int
    let muted: Bool

    var body: some View {
        Text(count > 99 ? "99+" : String(count))
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(muted ? Color.gray : Color.red, in: .capsule)
            .accessibilityLabel("\(count) 条未读")
    }
}

/// 没有头像数据，用名字的第一个字加一个由 id 决定的底色代替
struct AvatarView: View {
    let name: String
    let seed: String
    let isGroup: Bool

    private static let palette: [Color] = [.blue, .teal, .indigo, .orange, .pink, .purple, .green, .brown]

    var body: some View {
        RoundedRectangle(cornerRadius: isGroup ? 9 : 18, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Text(name.prefix(1).uppercased())
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var color: Color {
        // String.hashValue 每次启动都不一样，这里要一个稳定的
        let sum = seed.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
        return Self.palette[sum % Self.palette.count]
    }
}
