import FeishuChatCore
import SwiftUI

struct ChatListView: View {
    @Bindable var messages: MessagesState
    @State private var isManaging = false
    @State private var selectedIDs: Set<String> = []
    @State private var isRestoringScroll = true

    private var chats: [Chat] {
        messages.showsHiddenChats ? messages.hiddenChats : messages.chats
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    chatList
                        .coordinateSpace(name: "chat-list")
                        .onPreferenceChange(VisibleScrollRows.self) { frames in
                            guard !isRestoringScroll,
                                  let id = VisibleScrollRows.first(in: frames, height: viewport.size.height) else { return }
                            messages.listScrollAnchors[messages.showsHiddenChats] = id
                        }
                        .task(id: messages.showsHiddenChats) {
                            isRestoringScroll = true
                            await Task.yield()
                            if let id = messages.listScrollAnchors[messages.showsHiddenChats] {
                                proxy.scrollTo(id, anchor: .top)
                            }
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            isRestoringScroll = false
                        }
                }
            }
            if isManaging {
                Divider()
                managementFooter
            }
        }
        .overlay {
            if chats.isEmpty {
                Text(messages.showsHiddenChats ? "没有隐藏的会话" : "暂无会话")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: messages.showsHiddenChats) { _, _ in endManagement() }
        .onChange(of: chats.map(\.id)) { _, ids in selectedIDs.formIntersection(ids) }
    }

    @ViewBuilder
    private var chatList: some View {
        if isManaging {
            List(chats) { chat in
                Toggle(isOn: Binding(
                    get: { selectedIDs.contains(chat.id) },
                    set: { selected in
                        if selected { selectedIDs.insert(chat.id) }
                        else { selectedIDs.remove(chat.id) }
                    }
                )) {
                    ChatRowView(chat: chat)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("选择\(chat.displayName)")
                .id(chat.id)
                .trackScrollRow(chat.id, space: "chat-list")
            }
        } else {
            List(chats, selection: $messages.selectedChatID) { chat in
                ChatRowView(chat: chat)
                    .id(chat.id)
                    .trackScrollRow(chat.id, space: "chat-list")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if messages.showsHiddenChats {
                Button { messages.showChatList(hidden: false) } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .help("返回会话列表")
            }
            Text(messages.showsHiddenChats ? "隐藏会话" : "会话")
                .font(.headline)
            Spacer(minLength: 4)
            if isManaging {
                Menu("管理") {
                    if !messages.showsHiddenChats {
                        Button("查看隐藏会话（\(messages.hiddenChats.count)）") {
                            messages.showChatList(hidden: true)
                        }
                    }
                    Button("全选") { selectedIDs = Set(chats.map(\.id)) }
                        .disabled(chats.isEmpty)
                    Button("取消全选") { selectedIDs.removeAll() }
                        .disabled(selectedIDs.isEmpty)
                    Divider()
                    Button("完成管理") { endManagement() }
                }
                .fixedSize()
            } else {
                Button("管理") { isManaging = true }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var managementFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(messages.showsHiddenChats ? "取消隐藏后，会话会回到主列表。" : "隐藏后，新消息也不会让会话回到主列表。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("已选 \(selectedIDs.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { endManagement() }
                Button(messages.showsHiddenChats ? "取消隐藏" : "隐藏") {
                    messages.setChatsHidden(selectedIDs, hidden: !messages.showsHiddenChats)
                    selectedIDs.removeAll()
                }
                .disabled(selectedIDs.isEmpty || messages.status?.user == nil)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func endManagement() {
        isManaging = false
        selectedIDs.removeAll()
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

struct UnreadBadge: View {
    let count: Int
    let muted: Bool

    var body: some View {
        Text(UnreadCounts.label(for: count) ?? "")
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
