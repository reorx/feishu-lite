import FeishuLiteCore
import Foundation
import os

@MainActor
protocol MessageNotifications: AnyObject {
    func notify(message: Message, chat: Chat)
    func notifySessionExpired()
    func clearSessionExpired()
    func clearNotifications(chatID: String)
}

/// 聊天领域状态常驻；工作区视图重建不影响同步、当前会话或草稿。
@MainActor
@Observable
final class MessagesState {
    private(set) var status: BackendStatus?
    private(set) var chats: [Chat] = []
    private(set) var hiddenChats: [Chat] = []
    private(set) var unreadCount = 0
    var showsHiddenChats = false
    private(set) var conversation: Conversation?
    var selectedChatID: String? {
        didSet {
            if selectedChatID != oldValue { selectionChanged(from: oldValue) }
        }
    }
    var isConfirmingLogout = false
    /// 可见/隐藏列表各留一个锚点；每个会话留自己的详情锚点。
    var listScrollAnchors: [Bool: String] = [:]
    var detailScrollAnchors: [String: String] = [:]
    let login: LoginModel

    var isLoggedIn: Bool {
        guard let status else { return false }
        return status.state != .loggedOut
    }

    @ObservationIgnored var viewingContext: () -> ViewingContext = {
        ViewingContext(activeModule: .messages, isAppActive: false, isWindowVisible: false, selectedChatID: nil)
    }
    @ObservationIgnored var onUnreadCountChange: ((Int) -> Void)?
    @ObservationIgnored private var chatList = ChatList() {
        didSet {
            chats = chatList.visibleChats
            hiddenChats = chatList.hiddenChats
            unreadCount = chatList.badgeCount
            onUnreadCountChange?(unreadCount)
        }
    }
    @ObservationIgnored private var drafts: [String: String] = [:]
    @ObservationIgnored private let hiddenPreferences = HiddenChatPreferences()
    @ObservationIgnored private let connection: BackendConnection
    @ObservationIgnored private let notifications: any MessageNotifications
    @ObservationIgnored private let log = Logger(subsystem: "com.reorx.FeishuLite", category: "messages")

    init(connection: BackendConnection, notifications: any MessageNotifications) {
        self.connection = connection
        self.notifications = notifications
        login = LoginModel(connection: connection)
    }

    func updateLoginVisibility() {
        if viewingContext().activeModule.shouldStartChatLogin(state: status?.state), connection.client != nil {
            login.begin()
        } else {
            login.end()
        }
    }

    func handle(_ event: BackendEvent) {
        switch event {
        case let .status(status):
            apply(status)
        case let .chatUpdated(chat):
            chatList.upsert(chat)
            reloadConversationIfBehind(chat)
        case let .messageNew(message, chat):
            received(message, in: chat)
        case .mail:
            break
        }
    }

    private func apply(_ new: BackendStatus) {
        let old = status
        status = new
        if old?.user?.id != new.user?.id {
            selectedChatID = nil
            showsHiddenChats = false
            drafts.removeAll()
            listScrollAnchors.removeAll()
            detailScrollAnchors.removeAll()
            chatList = ChatList(hiddenIDs: new.user.map { hiddenPreferences.load(userID: $0.id) } ?? [])
        }
        switch new.state {
        case .loggedOut:
            selectedChatID = nil
            showsHiddenChats = false
            drafts.removeAll()
            listScrollAnchors.removeAll()
            detailScrollAnchors.removeAll()
            chatList = ChatList()
            if let error = new.lastError, old?.state != .loggedOut || old?.lastError != error {
                notifications.notifySessionExpired()
            }
            updateLoginVisibility()
        case .online:
            login.end()
            notifications.clearSessionExpired()
            if let old, old.state != .online {
                Task { await refreshChats() }
            }
        case .connecting, .reconnecting:
            login.end()
        }
    }

    private func received(_ message: Message, in chat: Chat) {
        var chat = chat
        let context = viewingContext()
        let isViewing = context.shouldMarkChatRead(chatID: chat.id, hasLoaded: conversation?.hasLoaded == true,
                                                  unread: chat.unread, onlyIfUnread: false)
        if isViewing {
            chat.unread = 0
        }
        chatList.upsert(chat)
        conversation?.receive(message)
        if isViewing {
            markReadIfViewing(onlyIfUnread: false)
        }
        if NotificationPolicy.shouldNotify(message: message, chat: chat, context: context.notificationContext) {
            notifications.notify(message: message, chat: chat)
        }
    }

    /// 事件流（重新）连上之后：断开期间的变化不会补发事件，所以会话列表和当前会话都重新拉一遍
    func refreshAfterConnect() async {
        guard isLoggedIn else { return }
        await refreshChats()
        if let conversation, let chat = chatList[conversation.chatID] {
            await conversation.loadLatest(chatLastPosition: chat.lastPosition)
            markReadIfViewing(onlyIfUnread: true)
        }
    }

    private func refreshChats() async {
        do {
            chatList.replaceAll(try await connection.requireClient().chats())
            if let selectedChatID, chatList[selectedChatID] == nil {
                self.selectedChatID = nil
            }
        } catch {
            log.error("failed to load chats: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 断线补拉只发 chat.updated 不发 message.new：当前会话落后于服务端时重新拉最新一页
    private func reloadConversationIfBehind(_ chat: Chat) {
        guard let conversation, conversation.chatID == chat.id, conversation.hasLoaded,
              chat.lastPosition > (conversation.latestPosition ?? -1) else { return }
        Task {
            await conversation.loadLatest(chatLastPosition: chat.lastPosition)
            markReadIfViewing(onlyIfUnread: true)
        }
    }

    // MARK: - 会话

    func setChatsHidden(_ ids: Set<String>, hidden: Bool) {
        guard let userID = status?.user?.id else { return }
        if let selectedChatID, ids.contains(selectedChatID) {
            self.selectedChatID = nil
        }
        if hidden {
            chatList.hiddenIDs.formUnion(ids)
        } else {
            chatList.hiddenIDs.subtract(ids)
        }
        hiddenPreferences.save(chatList.hiddenIDs, userID: userID)
    }

    func showChatList(hidden: Bool) {
        selectedChatID = nil
        showsHiddenChats = hidden
    }

    private func selectionChanged(from oldID: String?) {
        if let oldID, let conversation, conversation.chatID == oldID {
            drafts[oldID] = conversation.draft.isEmpty ? nil : conversation.draft
        }
        guard let id = selectedChatID, let chat = chatList[id] else {
            conversation = nil
            return
        }
        let opened = Conversation(chat: chat, draft: drafts[id] ?? "", connection: connection)
        conversation = opened
        Task {
            await opened.loadLatest(chatLastPosition: chat.lastPosition)
            if conversation === opened {
                markReadIfViewing(onlyIfUnread: false)
            }
        }
    }

    /// 点通知进来：把窗口叫出来并选中会话
    func openChat(_ chatID: String) {
        guard isLoggedIn else { return }
        if chatList[chatID] != nil {
            showsHiddenChats = chatList.hiddenIDs.contains(chatID)
            selectedChatID = chatID
            return
        }
        Task {
            await refreshChats()
            if chatList[chatID] != nil {
                showsHiddenChats = chatList.hiddenIDs.contains(chatID)
                selectedChatID = chatID
            }
        }
    }

    /// 已读策略：只有用户真的看着这个会话时才标已读，手机上的未读会跟着清掉
    func markReadIfViewing(onlyIfUnread: Bool) {
        guard let id = selectedChatID, var chat = chatList[id],
              viewingContext().shouldMarkChatRead(chatID: id, hasLoaded: conversation?.hasLoaded == true,
                                                  unread: chat.unread, onlyIfUnread: onlyIfUnread) else { return }
        if chat.unread != 0 {
            chat.unread = 0
            chatList.upsert(chat)
        }
        notifications.clearNotifications(chatID: id)
        Task {
            do {
                try await connection.requireClient().markRead(chatID: id)
            } catch {
                log.error("mark read failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 登出

    func logout() async {
        do {
            try await connection.requireClient().logout()
        } catch {
            log.error("logout failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
