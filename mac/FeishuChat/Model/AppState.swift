import AppKit
import FeishuChatCore
import Foundation
import os

/// App 的全部状态：后端连接、登录状态、会话列表、当前会话。事件流是唯一的实时数据来源。
@MainActor
@Observable
final class AppState {
    static let reconnectBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]

    private(set) var backendState: BackendSupervisor.State = .stopped
    private(set) var isEventStreamConnected = false
    private(set) var status: BackendStatus?
    private(set) var chats: [Chat] = []
    private(set) var conversation: Conversation?
    var selectedChatID: String? {
        didSet {
            if selectedChatID != oldValue {
                selectionChanged(from: oldValue)
            }
        }
    }
    var isConfirmingLogout = false

    let login: LoginModel
    let notifications: NotificationService

    var isLoggedIn: Bool {
        guard let status else { return false }
        return status.state != .loggedOut
    }

    @ObservationIgnored private var chatList = ChatList() {
        didSet {
            chats = chatList.chats
            notifications.setBadge(chatList.badgeCount)
        }
    }
    @ObservationIgnored private var drafts: [String: String] = [:]
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private let connection = BackendConnection()
    @ObservationIgnored private let supervisor: BackendSupervisor
    @ObservationIgnored private let windows: WindowManager
    @ObservationIgnored private let log = Logger(subsystem: "com.reorx.FeishuChat", category: "app")

    init(supervisor: BackendSupervisor, notifications: NotificationService, windows: WindowManager) {
        self.supervisor = supervisor
        self.notifications = notifications
        self.windows = windows
        login = LoginModel(connection: connection)
    }

    // MARK: - 生命周期

    func start() {
        supervisor.onStateChange = { [weak self] state in self?.backendStateChanged(state) }
        notifications.onOpenChat = { [weak self] chatID in self?.openChat(chatID) }
        notifications.onOpenApp = { [weak self] in self?.windows.show() }
        notifications.activate()
        observeUserReturning()
        supervisor.start()
    }

    func shutdown() {
        eventTask?.cancel()
        supervisor.stop()
    }

    private func backendStateChanged(_ state: BackendSupervisor.State) {
        backendState = state
        eventTask?.cancel()
        eventTask = nil
        isEventStreamConnected = false
        guard case let .ready(endpoint) = state else {
            connection.client = nil
            return
        }
        let client = BackendClient(endpoint: endpoint)
        connection.client = client
        eventTask = Task { await runEventLoop(client) }
    }

    /// 用户回到 App（切回前台、窗口重新成为当前窗口）时，正开着的会话要补一次已读
    private func observeUserReturning() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.markReadIfViewing(onlyIfUnread: true)
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { await self?.notifications.refreshAuthorization() }
        })
    }

    // MARK: - 事件流

    private func runEventLoop(_ client: BackendClient) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                for try await event in client.events() {
                    let justConnected = !isEventStreamConnected
                    isEventStreamConnected = true
                    attempt = 0
                    handle(event)
                    if justConnected {
                        await refreshAfterConnect()
                    }
                }
            } catch {
                log.warning("event stream ended: \(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled { return }
            isEventStreamConnected = false
            let delay = Self.reconnectBackoff[min(attempt, Self.reconnectBackoff.count - 1)]
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }

    private func handle(_ event: BackendEvent) {
        switch event {
        case let .status(status):
            apply(status)
        case let .chatUpdated(chat):
            chatList.upsert(chat)
            reloadConversationIfBehind(chat)
        case let .messageNew(message, chat):
            received(message, in: chat)
        }
    }

    private func apply(_ new: BackendStatus) {
        let old = status
        status = new
        switch new.state {
        case .loggedOut:
            selectedChatID = nil
            drafts.removeAll()
            chatList = ChatList()
            if let error = new.lastError, old?.state != .loggedOut || old?.lastError != error {
                notifications.notifySessionExpired()
            }
            login.begin()
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
        let context = NotificationContext(isAppActive: NSApp.isActive, isWindowVisible: windows.isShowingContent,
                                          selectedChatID: selectedChatID)
        let isViewing = context.viewingChatID == chat.id
        if isViewing {
            chat.unread = 0
        }
        chatList.upsert(chat)
        conversation?.receive(message)
        if isViewing {
            markReadIfViewing(onlyIfUnread: false)
        }
        if NotificationPolicy.shouldNotify(message: message, chat: chat, context: context) {
            notifications.notify(message: message, chat: chat)
        }
    }

    /// 事件流（重新）连上之后：断开期间的变化不会补发事件，所以会话列表和当前会话都重新拉一遍
    private func refreshAfterConnect() async {
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
        windows.show()
        guard isLoggedIn else { return }
        if chatList[chatID] != nil {
            selectedChatID = chatID
            return
        }
        Task {
            await refreshChats()
            if chatList[chatID] != nil {
                selectedChatID = chatID
            }
        }
    }

    /// 已读策略：只有用户真的看着这个会话时才标已读，手机上的未读会跟着清掉
    private func markReadIfViewing(onlyIfUnread: Bool) {
        guard windows.isShowingContent, let id = selectedChatID, var chat = chatList[id],
              conversation?.hasLoaded == true else { return }
        if onlyIfUnread, chat.unread == 0 { return }
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
