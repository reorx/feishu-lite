import AppKit
import FeishuChatCore
import Foundation
import os

/// 应用外壳：后端生命周期、单条 SSE、模块选择、时钟、badge 与通知路由。
@MainActor
@Observable
final class AppState {
    static let reconnectBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]
    private(set) var backendState: BackendSupervisor.State = .stopped
    private(set) var isEventStreamConnected = false
    private(set) var status: BackendStatus?
    private(set) var today = Calendar.current.startOfDay(for: Date())
    var activeModule: AppModule {
        didSet {
            guard activeModule != oldValue else { return }
            preferences.set(activeModule.rawValue, forKey: Self.modulePreferenceKey)
            // 先撤掉 NSTextView 的焦点，再由 RootView 销毁旧工作区。
            windows.window?.makeFirstResponder(nil)
            messages.updateLoginVisibility()
            reevaluateViewing()
        }
    }
    private(set) var unreadCounts = UnreadCounts(messages: 0, email: 0)
    /// D 阶段接入 MailState 后消费目标；B 阶段仅保存类型化目标并显示占位。
    private(set) var pendingMailRoute: NotificationRoute?
    let messages: MessagesState
    let notifications: NotificationService

    var viewingContext: ViewingContext {
        ViewingContext(activeModule: activeModule, isAppActive: NSApp.isActive,
                       isWindowVisible: windows.isShowingContent, selectedChatID: messages.selectedChatID,
                       selectedMail: pendingMailRoute)
    }

    private static let modulePreferenceKey = "active-module"
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private let connection = BackendConnection()
    @ObservationIgnored private let supervisor: BackendSupervisor
    @ObservationIgnored private let windows: any AppWindows
    @ObservationIgnored private let log = Logger(subsystem: "com.reorx.FeishuChat", category: "app")

    init(supervisor: BackendSupervisor, notifications: NotificationService, windows: any AppWindows,
         preferences: UserDefaults = .standard) {
        self.supervisor = supervisor
        self.notifications = notifications
        self.windows = windows
        self.preferences = preferences
        activeModule = preferences.string(forKey: Self.modulePreferenceKey).flatMap(AppModule.init(rawValue:)) ?? .messages
        messages = MessagesState(connection: connection, notifications: notifications)
        messages.viewingContext = { [weak self] in
            self?.viewingContext ?? ViewingContext(activeModule: .messages, isAppActive: false,
                                                  isWindowVisible: false, selectedChatID: nil)
        }
        messages.onUnreadCountChange = { [weak self] count in self?.updateUnread(messages: count) }
    }

    // MARK: - 生命周期

    func start() {
        supervisor.onStateChange = { [weak self] state in self?.backendStateChanged(state) }
        notifications.onOpenRoute = { [weak self] route in self?.open(route) }
        notifications.onOpenApp = { [weak self] in self?.openMessages() }
        notifications.activate()
        observeUserReturning()
        observeDayChange()
        supervisor.start()
    }

    func shutdown() {
        eventTask?.cancel()
        messages.login.end()
        supervisor.stop()
    }

    func retryBackendInstallation() {
        supervisor.start()
    }

    private func backendStateChanged(_ state: BackendSupervisor.State) {
        backendState = state
        eventTask?.cancel()
        eventTask = nil
        isEventStreamConnected = false
        guard case let .ready(endpoint) = state else {
            connection.client = nil
            messages.login.end()
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
                    self?.reevaluateViewing()
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            Task { await self?.notifications.refreshAuthorization() }
        })
    }

    /// 跨天、改时区、睡眠唤醒之后更新 `today`
    private func observeDayChange() {
        let sources: [(NotificationCenter, Notification.Name)] = [
            (.default, .NSCalendarDayChanged),
            (.default, .NSSystemTimeZoneDidChange),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ]
        for (center, name) in sources {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshToday()
                }
            })
        }
    }

    private func refreshToday() {
        let start = Calendar.current.startOfDay(for: Date())
        if start != today {
            today = start
        }
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
                        await messages.refreshAfterConnect()
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
        if case let .status(new) = event { status = new }
        messages.handle(event)
        // C/D 的 mail.* 事件在此按领域分派，不在工作区视图里创建 SSE。
    }

    func reevaluateViewing() {
        messages.markReadIfViewing(onlyIfUnread: true)
        // D 阶段在同一入口补 MailState 的成功正文可见性判断。
    }

    /// 两个领域上报真实总数；Dock badge 只从此处写入。
    func updateUnread(messages: Int? = nil, email: Int? = nil) {
        unreadCounts = UnreadCounts(messages: messages ?? unreadCounts.messages, email: email ?? unreadCounts.email)
        notifications.setBadge(unreadCounts.total)
    }

    func open(_ route: NotificationRoute) {
        activeModule = route.module
        windows.show()
        switch route {
        case let .messages(chatID): messages.openChat(chatID)
        case .email: pendingMailRoute = route
        }
        reevaluateViewing()
    }

    private func openMessages() {
        activeModule = .messages
        windows.show()
        reevaluateViewing()
    }
}
