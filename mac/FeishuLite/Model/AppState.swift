import AppKit
import FeishuLiteCore
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
    /// D2 消费目标前不代表已选中或正文已显示。
    private(set) var pendingMailRoute: NotificationRoute?
    let messages: MessagesState
    let mail: MailState
    let notifications: NotificationService
    let mailNotifications: MailNotificationCoordinator

    var viewingContext: ViewingContext {
        ViewingContext(activeModule: activeModule, isAppActive: NSApp?.isActive ?? false,
                       isWindowVisible: windows.isShowingContent, selectedChatID: messages.selectedChatID,
                       selectedMail: mail.displayedBodyRoute)
    }

    private static let modulePreferenceKey = "active-module"
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var mailWork: Task<Void, Never>?
    @ObservationIgnored private var chatWork: Task<Void, Never>?
    @ObservationIgnored private var routeWork: Task<Void, Never>?
    @ObservationIgnored private var routeRevision = 0
    @ObservationIgnored private var wakeWork: Task<Void, Never>?
    @ObservationIgnored private var wakeRequested = false
    @ObservationIgnored private var workspaceObservers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var wantsMailRefresh = false
    @ObservationIgnored private var wantsCredentialRestore = false
    @ObservationIgnored private var wantsChatRefresh = false
    @ObservationIgnored private var chatStatusRevision = 0
    var activeEventWorkCount: Int { (mailWork == nil ? 0 : 1) + (chatWork == nil ? 0 : 1) }
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private let connection = BackendConnection()
    @ObservationIgnored private let supervisor: BackendSupervisor
    @ObservationIgnored private let windows: any AppWindows
    @ObservationIgnored private var backendEpoch = 0
    @ObservationIgnored private let makeClient: (BackendEndpoint) -> BackendClient
    @ObservationIgnored private let log = Logger(subsystem: "com.reorx.FeishuLite", category: "app")

    init(supervisor: BackendSupervisor, notifications: NotificationService, windows: any AppWindows,
         preferences: UserDefaults = .standard, credentials: (any MailCredentialStore)? = nil,
         makeClient: @escaping (BackendEndpoint) -> BackendClient = { BackendClient(endpoint: $0) }) {
        self.supervisor = supervisor
        self.notifications = notifications
        self.windows = windows
        self.preferences = preferences
        self.makeClient = makeClient
        activeModule = preferences.string(forKey: Self.modulePreferenceKey).flatMap(AppModule.init(rawValue:)) ?? .messages
        messages = MessagesState(connection: connection, notifications: notifications, preferences: preferences)
        mail = MailState(connection: connection, credentials: credentials ?? MailKeychain(), externalBackend: supervisor.managesMailCredentials,
                         preferences: preferences)
        mailNotifications = MailNotificationCoordinator(mail:mail,notifications:notifications,preferences:preferences)
        messages.viewingContext = { [weak self] in
            self?.viewingContext ?? ViewingContext(activeModule: .messages, isAppActive: false,
                                                  isWindowVisible: false, selectedChatID: nil)
        }
        messages.onUnreadCountChange = { [weak self] count in self?.updateUnread(messages: count) }
        mail.viewingContext = { [weak self] in
            self?.viewingContext ?? ViewingContext(activeModule: .email, isAppActive: false,
                                                  isWindowVisible: false, selectedChatID: nil)
        }
        mail.onUnreadCountChange = { [weak self] count in self?.updateUnread(email: count) }
        mail.onAccountRemoved = { [weak self] id in
            if case let .email(accountID, _, _) = self?.pendingMailRoute, accountID == id { self?.pendingMailRoute = nil }
            self?.mailNotifications.removeAccount(id)
        }
        mail.onNotificationChange = { [weak self] in
            self?.mailNotifications.request()
            self?.requestRouteWork()
            if self?.wakeRequested == true { self?.systemDidWake() }
        }
        mail.onReadIDs = { [weak self] ids, account in self?.mailNotifications.invalidate(ids:ids,account:account) }
        mail.onEvent = { [weak self] event in
            if let account = event.accountID {
                if event.reset { self?.mailNotifications.resetAccount(account) }
                self?.mailNotifications.invalidate(ids:event.readIDs + event.deletedIDs,account:account)
            }
        }
        notifications.onAuthorizationChange = { [weak self] in self?.mailNotifications.request() }
    }

    // MARK: - 生命周期

    func start() {
        supervisor.onStateChange = { [weak self] state in self?.backendStateChanged(state) }
        notifications.onOpenRoute = { [weak self] route in self?.open(route) }
        notifications.onOpenApp = { [weak self] in self?.openMessages() }
        notifications.activate()
        observeUserReturning()
        observeDayChange()
        observeWake()
        supervisor.start()
    }

    func shutdown() {
        eventTask?.cancel()
        backendEpoch += 1
        cancelEventWork()
        mail.backendChanged(ready: false)
        mailNotifications.stop()
        routeWork?.cancel(); wakeWork?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        workspaceObservers.forEach { $0.0.removeObserver($0.1) }; workspaceObservers = []
        messages.login.end()
        supervisor.stop()
    }

    func retryBackendInstallation() {
        supervisor.stop()
        supervisor.start()
    }

    func backendStateChanged(_ state: BackendSupervisor.State, startEventLoop: Bool = true) {
        backendEpoch += 1
        backendState = state
        eventTask?.cancel()
        eventTask = nil
        cancelEventWork()
        isEventStreamConnected = false
        mailNotifications.backendChanged()
        routeRevision += 1; routeWork?.cancel()
        wakeWork?.cancel(); wakeWork = nil
        status = nil
        guard case let .ready(endpoint) = state else {
            mail.backendChanged(ready: false)
            connection.client = nil
            messages.login.end()
            return
        }
        let client = makeClient(endpoint)
        connection.client = client
        mail.backendChanged(ready: true)
        let epoch = backendEpoch
        if wakeRequested { systemDidWake() }
        requestRouteWork()
        if startEventLoop { eventTask = Task { await runEventLoop(client, epoch: epoch) } }
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
        ]
        for (center, name) in sources {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshToday()
                }
            }
            observers.append(observer)
        }
    }
    func observeWake(center: NotificationCenter? = nil) {
        let center = center ?? NSWorkspace.shared.notificationCenter
        guard workspaceObservers.isEmpty else { return }
        let observer = center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshToday()
                self?.systemDidWake()
            }
        }
        workspaceObservers.append((center,observer))
    }

    private func refreshToday() {
        let start = Calendar.current.startOfDay(for: Date())
        if start != today {
            today = start
        }
    }

    // MARK: - 事件流

    private func runEventLoop(_ client: BackendClient, epoch: Int) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await consumeEventStream(client.events(), epoch: epoch)
                attempt = 0
            } catch {
                log.warning("event stream ended: \(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled || epoch != backendEpoch { return }
            isEventStreamConnected = false
            mail.streamDisconnected()
            let delay = Self.reconnectBackoff[min(attempt, Self.reconnectBackoff.count - 1)]
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }

    /// 两领域 HTTP 的等待不阻挡下一条 SSE；重启时统一取消这些有限任务。
    func consumeEventStream(_ stream: AsyncThrowingStream<BackendEvent, Error>, epoch: Int? = nil) async throws {
        let epoch = epoch ?? backendEpoch
        for try await event in stream {
            guard epoch == backendEpoch, !Task.isCancelled else { return }
            let justConnected = !isEventStreamConnected
            isEventStreamConnected = true
            receiveStreamEvent(event)
            if justConnected { beginStreamRecovery() }
        }
    }

    func receiveStreamEvent(_ event: BackendEvent) {
        switch event {
        case let .mail(event):
            mail.receive(event)
            if event.type == .status { requestMailWork(refresh: false) }
        case let .status(new):
            chatStatusRevision += 1
            status = new
            messages.handle(event)
            if mail.updateCapability(features: new.features) { requestMailWork(refresh: true) }
            if wakeRequested { systemDidWake() }
        default: messages.handle(event)
        }
    }

    private func cancelEventWork() {
        mailWork?.cancel()
        chatWork?.cancel()
        mailWork = nil
        chatWork = nil
        wantsMailRefresh = false
        wantsCredentialRestore = false
        wantsChatRefresh = false
    }

    private func requestMailWork(refresh: Bool) {
        wantsMailRefresh = wantsMailRefresh || refresh
        wantsCredentialRestore = true
        guard mailWork == nil else { return }
        let epoch = backendEpoch
        mailWork = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == self.backendEpoch { self.mailWork = nil } }
            while epoch == self.backendEpoch, !Task.isCancelled, self.wantsMailRefresh || self.wantsCredentialRestore {
                let refresh = self.wantsMailRefresh
                self.wantsMailRefresh = false
                self.wantsCredentialRestore = false
                if refresh { await self.mail.refreshStatus() }
                else { await self.mail.restoreCredentialIfNeeded() }
            }
        }
    }

    func handle(_ event: BackendEvent) async {
        receiveStreamEvent(event)
        await mailWork?.value
    }

    private func beginStreamRecovery() {
        isEventStreamConnected = true
        mail.streamDidConnect()
        mail.requestReaderRefresh()
        requestMailWork(refresh: true)
        wantsChatRefresh = true
        guard chatWork == nil else { return }
        let epoch = backendEpoch
        chatWork = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == self.backendEpoch { self.chatWork = nil } }
            while epoch == self.backendEpoch, !Task.isCancelled, self.wantsChatRefresh {
                self.wantsChatRefresh = false
                let version = self.chatStatusRevision
                if let client = self.connection.client {
                    do {
                        let new = try await client.status()
                        guard epoch == self.backendEpoch, !Task.isCancelled else { return }
                        if version == self.chatStatusRevision { self.receiveStreamEvent(.status(new)) }
                    } catch {
                        self.log.warning("failed to refresh backend status")
                    }
                }
                guard epoch == self.backendEpoch, !Task.isCancelled else { return }
                await self.messages.refreshAfterConnect()
            }
        }
    }

    /// 唯一 SSE 的恢复入口；消费循环只启动有界任务，不等待 HTTP。
    func refreshAfterEventStreamConnected() async {
        beginStreamRecovery()
        await chatWork?.value
        await mailWork?.value
    }

    func reevaluateViewing() {
        messages.markReadIfViewing(onlyIfUnread: true)
        mail.reevaluateViewing()
    }

    /// 两个领域上报真实总数；Dock badge 只从此处写入。
    func updateUnread(messages: Int? = nil, email: Int? = nil) {
        unreadCounts = UnreadCounts(messages: messages ?? unreadCounts.messages, email: email ?? unreadCounts.email)
        notifications.setBadge(unreadCounts.total)
    }

    func open(_ route: NotificationRoute) {
        routeRevision += 1
        routeWork?.cancel()
        activeModule = route.module
        windows.show()
        switch route {
        case let .messages(chatID): pendingMailRoute = nil; messages.openChat(chatID)
        case .email: pendingMailRoute = route
        }
        requestRouteWork()
        reevaluateViewing()
    }

    /// E can consume a notification route after capability/account recovery.
    /// This is loading only; delivery/ack stay with the notification integration.
    func loadPendingMailRoute() async {
        guard let route = pendingMailRoute, mail.capability == .supported,
              canLoadMailRoute else { return }
        let revision = routeRevision
        await mail.openRoute(route)
        if pendingMailRoute == route, revision == routeRevision, !Task.isCancelled { pendingMailRoute = nil }
        reevaluateViewing()
    }

    private func requestRouteWork() {
        guard routeWork == nil, pendingMailRoute != nil, mail.capability == .supported,
              canLoadMailRoute else { return }
        let epoch = backendEpoch
        routeWork = Task { [weak self] in
            guard let self else { return }
            defer {
                self.routeWork = nil
                if self.pendingMailRoute != nil { self.requestRouteWork() }
            }
            guard epoch == self.backendEpoch, !Task.isCancelled else { return }
            await self.loadPendingMailRoute()
        }
    }
    private var canLoadMailRoute: Bool {
        guard mail.isBackendReady, let status = mail.status else { return false }
        if case let .email(account, _, id) = pendingMailRoute,
           account == status.mailAccountID, id != nil { return status.uidvalidity != nil }
        return true
    }
    func waitForMailRoute() async { while let routeWork { await routeWork.value } }

    /// Workspace wake enters one coalesced reconnect; no chat login or keychain read here.
    func systemDidWake() {
        wakeRequested = true
        guard wakeWork == nil, mail.capability == .supported, mail.isBackendReady,
              mail.status?.mailAccountID != nil, let client = connection.client else { return }
        let epoch = backendEpoch
        wakeWork = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == self.backendEpoch { self.wakeWork = nil } }
            self.wakeRequested = false
            let account = self.mail.status?.mailAccountID
            do {
                _ = try await client.syncMail(reconnect:true,wait:true)
                guard epoch == self.backendEpoch, account == self.mail.status?.mailAccountID, !Task.isCancelled else { return }
                // The reconnect response may race with ordered SSE; get a versioned snapshot instead.
                await self.mail.refreshStatus()
                self.mailNotifications.request()
                self.mail.reevaluateViewing()
            } catch {
                guard epoch == self.backendEpoch, !Task.isCancelled else { return }
                await self.mail.refreshStatus()
            }
            self.wakeRequested = false // wake bursts during this reconnect are already covered
        }
    }
    func waitForWakeWork() async { await wakeWork?.value }

    private func openMessages() {
        activeModule = .messages
        windows.show()
        reevaluateViewing()
    }
}
