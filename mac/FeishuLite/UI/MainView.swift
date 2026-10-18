import FeishuLiteCore
import SwiftUI

/// Messages 工作区。未登录时侧栏只留头部，详情区是扫码页，窗口结构和已登录时一致。
struct MainView<Switcher: View>: View {
    let appState: AppState
    @Binding var sidebarVisibility: NavigationSplitViewVisibility
    let switcher: Switcher

    private var isLoggedOut: Bool { appState.messages.status?.state == .loggedOut }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            ModuleSidebar(switcher: switcher) {
                if isLoggedOut {
                    LoggedOutSidebar(status: status)
                } else {
                    ChatListView(messages: appState.messages, status: status)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            NotificationPermissionBar(notifications: appState.notifications)
                        }
                }
            }
        } detail: {
            if let status = appState.messages.status, status.state == .loggedOut {
                LoginView(login: appState.messages.login, sessionExpired: status.lastError != nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Messages")
            } else if let conversation = appState.messages.conversation {
                ConversationView(conversation: conversation, title: appState.messages.selectedChatName,
                                 messages: appState.messages)
                    .id(conversation.chatID)
            } else {
                ContentUnavailableView("选择一个会话", systemImage: "bubble.left.and.bubble.right")
                    .navigationTitle("Messages")
            }
        }
        .toolbar { CollapsedSidebarStatus(status: status, visibility: $sidebarVisibility) }
    }

    private var status: SidebarStatus {
        appState.messages.connectionDisplay(isEventStreamConnected: appState.isEventStreamConnected).sidebarStatus
    }
}

/// 未登录时的侧栏：保留头部和状态，列表位置说明登录后才有会话。
private struct LoggedOutSidebar: View {
    let status: SidebarStatus

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(status: status) { Text("会话") }
            Divider()
            ListEmptyState(systemImage: "qrcode", title: "扫码登录后显示会话")
                .frame(maxHeight: .infinity)
        }
    }
}

/// 通知被关掉时的提示。系统不会再弹授权，只能引导用户去系统设置里打开。
private struct NotificationPermissionBar: View {
    let notifications: NotificationService

    var body: some View {
        if notifications.isDenied {
            VStack(spacing: 0) {
                Divider()
                NoticeBar(tone: .warning, systemImage: "bell.slash", title: "通知未开启，收不到新消息提醒",
                          action: InlineAction(title: "去开启") { notifications.openSystemSettings() })
                    .font(.caption)
                    .controlSize(.small)
            }
        }
    }
}

struct ConnectionDisplay: Equatable {
    var text: String
    var isHealthy: Bool

    var sidebarStatus: SidebarStatus {
        SidebarStatus(tone: isHealthy ? .healthy : .warning, text: text)
    }
}

extension MessagesState {
    var selectedChatName: String {
        guard let id = selectedChatID,
              let chat = (chats + hiddenChats).first(where: { $0.id == id }) else { return "" }
        return chat.displayName
    }

    func connectionDisplay(isEventStreamConnected: Bool) -> ConnectionDisplay {
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

extension EnvironmentValues {
    /// 今天零点，跨天时由 AppState 更新。显示时间标签的视图从这里取"现在"，跨天后才会重新算
    @Entry var today = Calendar.current.startOfDay(for: Date())
}

extension Chat {
    var displayName: String {
        name.isEmpty ? "未命名会话" : name
    }
}
