import FeishuChatCore
import SwiftUI

struct MainView: View {
    @Bindable var appState: AppState

    var body: some View {
        NavigationSplitView {
            ChatListView(chats: appState.chats, selection: $appState.selectedChatID)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ConnectionStatusBar(appState: appState)
                }
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            if let conversation = appState.conversation {
                ConversationView(conversation: conversation, title: appState.selectedChatName)
                    .id(conversation.chatID)
            } else {
                ContentUnavailableView("选择一个会话", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }
}

/// 侧栏顶部的连接状态
private struct ConnectionStatusBar: View {
    let appState: AppState

    var body: some View {
        let display = appState.connectionDisplay
        HStack(spacing: 6) {
            Circle()
                .fill(display.isHealthy ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(display.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("连接状态：\(display.text)")
    }
}

struct ConnectionDisplay: Equatable {
    var text: String
    var isHealthy: Bool
}

extension AppState {
    var selectedChatName: String {
        guard let id = selectedChatID, let chat = chats.first(where: { $0.id == id }) else { return "" }
        return chat.displayName
    }

    var connectionDisplay: ConnectionDisplay {
        guard isEventStreamConnected, let status else {
            return ConnectionDisplay(text: "正在连接本地后端…", isHealthy: false)
        }
        let name = status.user?.name ?? ""
        switch status.state {
        case .online:
            return ConnectionDisplay(text: name.isEmpty ? "在线" : "\(name) · 在线", isHealthy: true)
        case .connecting:
            return ConnectionDisplay(text: "正在连接飞书…", isHealthy: false)
        case .reconnecting:
            return ConnectionDisplay(text: "连接已断开，正在重连…", isHealthy: false)
        case .loggedOut:
            return ConnectionDisplay(text: "未登录", isHealthy: false)
        }
    }
}

extension Chat {
    var displayName: String {
        name.isEmpty ? "未命名会话" : name
    }
}
