import Foundation
import FeishuLiteCore

/// 常驻邮箱状态；配置界面不持有网络任务、SSE 或恢复密码。
@MainActor
@Observable
final class MailState: CustomReflectable {
    enum Capability: Equatable { case unknown, supported, unsupported }
    enum Operation: Equatable { case testing, saving, removing, syncing }
    enum BodyLoadState: Equatable { case idle, loading, loaded(MailBody), failed(String) }

    private(set) var capability: Capability = .unknown
    private(set) var status: MailStatus?
    private(set) var isBackendReady = false
    private(set) var isStreamConnected = false
    private(set) var operation: Operation?
    private(set) var connectionTest: MailConnectionTest?
    private(set) var errorMessage: String?
    private(set) var credentialIssue: MailKeychainError?
    private(set) var hasUnsavedCredential = false
    private(set) var pendingCredentialDeletions: Set<String>
    private(set) var cleanupError: String?
    var addressInput = "" { didSet { if addressInput != oldValue { connectionTest = nil } } }
    var passwordInput = "" { didSet { if passwordInput != oldValue { connectionTest = nil } } }

    // State survives workspace reconstruction; presentation proof never does.
    var selectedMessageID: String?
    var selectedFolderID = "INBOX"
    var listScrollAnchor: String?
    @ObservationIgnored let plainPositions = MailPlainPositionCache()
    @ObservationIgnored let htmlInteractions = MailHTMLInteractionCache()
    var bodyLoadState: BodyLoadState = .idle {
        didSet { bodyFailure = nil }
    }
    // 必须参与 Observation，供 canRetryBody 的视图依赖；任何正文状态变化都会清除旧分类。
    var bodyFailure: MailAPIError?
    var folders: [MailFolder] = []
    var items: [MailSummary] = []
    var selectedSummary: MailSummary?
    var nextCursor: String?
    var hasLoadedList = false
    var isRefreshingReader = false
    var isPaging = false
    var listError: String?
    var routeError: String?
    var readError: String?
    var isReading = false
    var renderToken: MailRenderToken?
    var displayedToken: MailRenderToken?
    var readerGeneration = 0
    var showsConfiguration = false
    private(set) var pending: [MailNotification] = []
    var selectedRoute: NotificationRoute? {
        guard let accountID = status?.mailAccountID, let selectedMessageID else { return nil }
        return .email(accountID: accountID, folderID: selectedFolderID, messageID: selectedMessageID)
    }
    var canSubmit: Bool { capability == .supported && isBackendReady && operation == nil }
    var hasValidInput: Bool {
        let parts = addressInput.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && addressInput.count <= 512
            && !addressInput.contains(where: { $0.isWhitespace }) && !passwordInput.isEmpty && passwordInput.count <= 4096
    }
    var stateDescription: String {
        guard let status else { return "正在读取邮箱状态…" }
        switch status.state {
        case .unconfigured: return "尚未配置邮箱"
        case .credentialMissing: return "等待邮箱专用密码"
        case .connecting: return "正在连接邮箱…"
        case .online: return "邮箱已连接"
        case .offline: return "邮箱离线，保留缓存与上次未读数"
        case .authFailed: return "专用密码已失效，请更新密码"
        }
    }
    nonisolated var customMirror: Mirror { Mirror(self, children: [:]) }

    @ObservationIgnored var onUnreadCountChange: ((Int) -> Void)?
    /// E 在此处理精确账号通知清理；不隐式 ack。
    @ObservationIgnored var onAccountRemoved: ((String) -> Void)?
    @ObservationIgnored var onEvent: ((MailEvent) -> Void)?
    @ObservationIgnored var onNotificationChange: (() -> Void)?
    @ObservationIgnored var onReadIDs: (([String], String) -> Void)?
    var notificationRevision: Int { revision }
    @ObservationIgnored var viewingContext: (() -> ViewingContext)?
    @ObservationIgnored var readerTask: Task<Void, Never>?
    @ObservationIgnored var readerTaskID = UUID()
    @ObservationIgnored var readTask: Task<Void, Never>?
    @ObservationIgnored var wantsReaderRefresh = false
    @ObservationIgnored var readerRevision = 0
    @ObservationIgnored var selectionRevision = 0
    @ObservationIgnored var readAttempts: Set<MailReaderIdentity> = []
    @ObservationIgnored var readTaskID = UUID()
    var readerWorkCount: Int { readerTask == nil ? 0 : 1 }
    var readerClient: BackendClient? { connection.client }
    var readerIdentity: MailReaderIdentity? {
        guard capability == .supported, isBackendReady, let id = status?.mailAccountID,
              let validity = status?.uidvalidity else { return nil }
        return MailReaderIdentity(epoch: backendEpoch, accountID: id, generation: readerGeneration,
                                  uidvalidity: validity, messageID: nil)
    }
    @ObservationIgnored private let connection: BackendConnection
    @ObservationIgnored private let credentials: any MailCredentialStore
    @ObservationIgnored private let externalBackend: Bool
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var backendEpoch = 0
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var generationBaseline = 0
    @ObservationIgnored private var operationID = 0
    @ObservationIgnored private var loadedAccounts: Set<String> = []
    @ObservationIgnored private var retiredAccounts: Set<String> = []
    @ObservationIgnored private var secrets: [String: MailSecret] = [:]
    @ObservationIgnored private var rejectedAccounts: Set<String> = []
    @ObservationIgnored private var injectionAttempts: Set<String> = []
    private static let cleanupKey = "mail-keychain-pending-deletions"

    init(connection: BackendConnection, credentials: any MailCredentialStore, externalBackend: Bool,
         preferences: UserDefaults = .standard) {
        self.connection = connection
        self.credentials = credentials
        self.externalBackend = externalBackend
        self.preferences = preferences
        pendingCredentialDeletions = Set(preferences.stringArray(forKey: Self.cleanupKey) ?? [])
    }

    /// 每次 supervisor 状态变化使旧进程请求失效；密码/一次性读取记录保留在 App 内存。
    func backendChanged(ready: Bool) {
        stopReader()
        invalidateReaderConnection()
        readerGeneration = 0
        backendEpoch += 1
        revision += 1
        operationID += 1
        isBackendReady = ready
        isStreamConnected = false
        capability = .unknown
        injectionAttempts.removeAll()
        generationBaseline = 0
        retiredAccounts.removeAll()
        operation = nil
        connectionTest = nil
        if var old = status {
            old.generation = 0
            old.unreadStale = true
            if old.state == .online || old.state == .connecting { old.state = .offline }
            status = old
        }
    }

    func setCapability(features: [String]) async {
        if updateCapability(features: features) { await refreshStatus() }
    }

    @discardableResult
    func updateCapability(features: [String]) -> Bool {
        let new: Capability = features.contains("mail") ? .supported : .unsupported
        let changed = capability != new
        capability = new
        return changed && new == .supported
    }

    func streamConnected() async {
        streamDidConnect()
        await refreshStatus()
    }
    func streamDidConnect() { isStreamConnected = true }
    func streamDisconnected() { isStreamConnected = false }

    func refreshStatus() async {
        guard capability == .supported, isBackendReady, let client = connection.client else { return }
        let epoch = backendEpoch
        let version = revision
        do {
            let new = try await client.mailStatus()
            guard epoch == backendEpoch, version == revision, !Task.isCancelled else { return }
            apply(new)
            prepareCredential()
            await injectIfNeeded()
        } catch {
            guard epoch == backendEpoch, version == revision, !Task.isCancelled else { return }
            errorMessage = safeMessage(error)
        }
    }

    func handle(_ event: MailEvent) async {
        receive(event)
        await restoreCredentialIfNeeded()
    }

    /// SSE 按 wire 顺序同步应用，不创建每事件 Task；网络恢复在唯一合并任务中执行。
    func receive(_ event: MailEvent) {
        guard capability == .supported, isBackendReady,
              event.generation >= generationBaseline,
              event.accountID.map({ !retiredAccounts.contains($0) }) ?? true else { return }
        if let new = event.status {
            guard new.mailAccountID == event.accountID, new.generation == event.generation else { return }
            apply(new)
        } else {
            guard event.accountID == status?.mailAccountID,
                  event.uidvalidity == status?.uidvalidity else { return }
            if readerGeneration != event.generation { invalidateReaderConnection() }
            generationBaseline = event.generation
            readerGeneration = event.generation
            revision += 1
            if let batch = event.notification {
                guard batch.accountID == event.accountID, batch.folderID == event.folderID,
                      batch.uidvalidity == event.uidvalidity else { return }
                pending.removeAll { $0.id == batch.id }
                pending.append(batch)
            }
            if event.reset {
                pending = []
                resetReader()
                clearSelection()
            } else if let selectedMessageID, event.deletedIDs.contains(selectedMessageID) {
                clearSelection()
            }
        }
        if event.folderID == "INBOX" {
            let invalid = Set(event.readIDs + event.deletedIDs)
            if !invalid.isEmpty { removePendingMembers(Array(invalid)) }
            applyReadIDs(event.readIDs)
            items.removeAll { event.deletedIDs.contains($0.id) }
            if event.type != .status { requestReaderRefresh() }
        }
        onEvent?(event)
        onNotificationChange?()
    }

    func restoreCredentialIfNeeded() async {
        guard capability == .supported, isBackendReady else { return }
        prepareCredential()
        await injectIfNeeded()
    }

    private func apply(_ new: MailStatus) {
        guard new.generation >= generationBaseline,
              new.mailAccountID.map({ !retiredAccounts.contains($0) }) ?? true else { return }
        let old = status
        let oldReaderGeneration = readerGeneration
        generationBaseline = new.generation
        readerGeneration = new.generation
        if status?.mailAccountID != new.mailAccountID {
            errorMessage = nil
            if let oldID = status?.mailAccountID {
                retiredAccounts.insert(oldID)
                secrets.removeValue(forKey: oldID)
                onAccountRemoved?(oldID)
            }
            clearSelection()
            resetReader()
            credentialIssue = nil
            hasUnsavedCredential = false
            addressInput = new.address ?? ""
            passwordInput = ""
        }
        if old?.mailAccountID == new.mailAccountID, old?.uidvalidity != new.uidvalidity {
            clearSelection()
            resetReader()
        } else if old?.generation != new.generation {
            invalidateReaderConnection()
        }
        revision += 1
        status = new
        if new.state == .unconfigured {
            status?.unreadCount = 0
            pending = []
        } else {
            pending = new.pending
        }
        if new.state == .authFailed, let id = new.mailAccountID { rejectedAccounts.insert(id) }
        onUnreadCountChange?(status?.unreadCount ?? 0)
        if readerIdentity != nil,
           old?.mailAccountID != new.mailAccountID || old?.uidvalidity != new.uidvalidity || oldReaderGeneration != new.generation {
            requestReaderRefresh()
        } else if hasLoadedList, old?.state != .online, new.state == .online { requestReaderRefresh() }
        reevaluateViewing()
        onNotificationChange?()
    }

    func applyNotificationAck(_ new: MailStatus, expected: MailReaderIdentity, revision: Int) {
        guard readerIdentity == expected, self.revision == revision else { return }
        guard new != status || new.pending != pending else { return }
        apply(new)
    }

    func removePendingMembers(_ ids: [String]) {
        for i in pending.indices { pending[i].items.removeAll { ids.contains($0.id) } }
        pending.removeAll { $0.items.isEmpty }
    }

    private func clearSelection() {
        invalidatePresentation()
        selectionRevision += 1
        selectedMessageID = nil
        selectedSummary = nil
        selectedFolderID = "INBOX"
        bodyLoadState = .idle
        listScrollAnchor = nil
        plainPositions.removeAll()
        htmlInteractions.removeAll()
    }

    /// 自动恢复一账号每次 App 生命周期最多读一次；不在未知能力/外部模式访问钥匙串。
    private func prepareCredential() {
        guard !externalBackend, capability == .supported, let id = status?.mailAccountID,
              !loadedAccounts.contains(id), secrets[id] == nil else { return }
        loadedAccounts.insert(id)
        do {
            secrets[id] = try credentials.read(accountID: id)
            credentialIssue = nil
        } catch {
            credentialIssue = (error as? MailKeychainError) ?? .other
        }
    }

    private func injectIfNeeded() async {
        guard !externalBackend, isBackendReady, isStreamConnected, capability == .supported,
              let id = status?.mailAccountID, let secret = secrets[id], !rejectedAccounts.contains(id),
              status?.state == .credentialMissing, !injectionAttempts.contains(id), let client = connection.client else { return }
        let epoch = backendEpoch
        let version = revision
        injectionAttempts.insert(id) // await 前登记，重复快照不能并发注入。
        do {
            let new = try await client.injectMailCredential(accountID: id, password: secret)
            guard epoch == backendEpoch, status?.mailAccountID == id, !Task.isCancelled,
                  version == revision || new.generation > generationBaseline else { return }
            apply(new)
            requestReaderRefresh()
        } catch {
            guard epoch == backendEpoch, status?.mailAccountID == id, !Task.isCancelled else { return }
            errorMessage = safeMessage(error)
            if let api = error as? MailAPIError, api.code == "authentication_failed" { rejectedAccounts.insert(id) }
            if (error as? MailAPIError)?.needsStatusRefresh == true { await refreshStatus() }
        }
    }

    func retryKeychain() async {
        guard !externalBackend, canSubmit, let id = status?.mailAccountID else { return }
        // 显式重读；被后端拒绝的密码仍不会后台重复注入。
        loadedAccounts.remove(id)
        secrets.removeValue(forKey: id)
        if !rejectedAccounts.contains(id) { injectionAttempts.remove(id) }
        prepareCredential()
        await injectIfNeeded()
    }

    private func begin(_ next: Operation) -> (Int, Int)? {
        guard canSubmit else { return nil }
        operationID += 1
        operation = next
        errorMessage = nil
        return (backendEpoch, operationID)
    }
    private func isCurrent(_ token: (Int, Int)) -> Bool {
        token.0 == backendEpoch && token.1 == operationID && !Task.isCancelled
    }
    private func finish(_ token: (Int, Int)) {
        if token.0 == backendEpoch && token.1 == operationID { operation = nil }
    }

    func testConnection() async {
        guard hasValidInput, let token = begin(.testing), let client = connection.client else { return }
        defer { finish(token) }
        let address = addressInput
        let secret = MailSecret(passwordInput)
        let account = status?.mailAccountID
        connectionTest = nil
        do {
            let result = try await client.testMailAccount(address: address, password: secret)
            guard isCurrent(token), address == addressInput, secret.withValue({ $0 == passwordInput }), account == status?.mailAccountID else { return }
            connectionTest = result
        } catch {
            guard isCurrent(token), address == addressInput, secret.withValue({ $0 == passwordInput }), account == status?.mailAccountID else { return }
            await recover(error)
        }
    }

    func saveAccount() async {
        guard hasValidInput, let token = begin(.saving), let client = connection.client else { return }
        defer { finish(token) }
        let address = addressInput
        let secret = MailSecret(passwordInput)
        let previous = status?.mailAccountID
        do {
            let change = try await client.configureMailAccount(address: address, password: secret)
            guard isCurrent(token), let account = change.account,
                  status?.mailAccountID == previous || status?.mailAccountID == account.id else { return }
            if let removed = change.removedAccountID { removeLocalAccount(removed) }
            // configure 已注入，先建立准确本地身份，再取真实同步状态；不能宣称 online。
            var configured = status?.mailAccountID == account.id ? status! :
                MailStatus(mailAccountID: account.id, generation: status?.generation ?? 0)
            configured.address = account.address
            configured.state = .connecting
            configured.unreadStale = true
            apply(configured)
            secrets[account.id] = secret
            loadedAccounts.insert(account.id)
            rejectedAccounts.remove(account.id)
            injectionAttempts.insert(account.id)
            passwordInput = ""
            saveCredential(secret, accountID: account.id, address: account.address)
            await refreshStatus()
        } catch {
            guard isCurrent(token) else { return }
            await recover(error)
            reconcileRemovalAfterRecovery(previous: previous, token: token)
        }
    }

    func updateCredential() async {
        guard !passwordInput.isEmpty, passwordInput.count <= 4096, let id = status?.mailAccountID,
              let token = begin(.saving), let client = connection.client else { return }
        defer { finish(token) }
        let secret = MailSecret(passwordInput)
        do {
            let new = try await client.injectMailCredential(accountID: id, password: secret)
            guard isCurrent(token), status?.mailAccountID == id else { return }
            apply(new)
            secrets[id] = secret
            loadedAccounts.insert(id)
            rejectedAccounts.remove(id)
            if new.state == .authFailed { rejectedAccounts.insert(id) }
            injectionAttempts.insert(id)
            passwordInput = ""
            saveCredential(secret, accountID: id, address: status?.address ?? "")
        } catch {
            guard isCurrent(token), status?.mailAccountID == id else { return }
            await recover(error)
        }
    }

    private func saveCredential(_ secret: MailSecret, accountID: String, address: String) {
        do {
            try credentials.write(secret, accountID: accountID, address: address)
            hasUnsavedCredential = false
            credentialIssue = nil
        } catch {
            hasUnsavedCredential = true
            credentialIssue = (error as? MailKeychainError) ?? .other
        }
    }
    func retryCredentialSave() async {
        guard canSubmit, let id = status?.mailAccountID, let secret = secrets[id] else { return }
        saveCredential(secret, accountID: id, address: status?.address ?? "")
    }

    func removeAccount() async {
        guard let token = begin(.removing), let client = connection.client else { return }
        defer { finish(token) }
        let previous = status?.mailAccountID
        do {
            let change = try await client.removeMailAccount()
            guard isCurrent(token), status?.mailAccountID == previous || status?.mailAccountID == nil else { return }
            if let removed = change.removedAccountID { removeLocalAccount(removed) }
            apply(MailStatus(generation: status?.generation ?? 0))
            passwordInput = ""
            addressInput = ""
            credentialIssue = nil
            hasUnsavedCredential = false
        } catch {
            guard isCurrent(token) else { return }
            await recover(error)
            reconcileRemovalAfterRecovery(previous: previous, token: token)
        }
    }

    /// 响应超时不等于变更未提交；只在新快照/SSE 已确认身份变化后清理旧 UUID。
    private func reconcileRemovalAfterRecovery(previous: String?, token: (Int, Int)) {
        guard isCurrent(token), let previous, let status, status.mailAccountID != previous else { return }
        removeLocalAccount(previous)
    }

    private func removeLocalAccount(_ id: String) {
        secrets.removeValue(forKey: id)
        loadedAccounts.remove(id)
        rejectedAccounts.remove(id)
        injectionAttempts.remove(id)
        retiredAccounts.insert(id)
        onAccountRemoved?(id)
        // 先落盘非秘密的精确 id，删除成功再移除；App 重启可继续手动清理。
        pendingCredentialDeletions.insert(id)
        persistCleanup()
        deleteCredential(id)
    }
    private func persistCleanup() {
        preferences.set(pendingCredentialDeletions.sorted(), forKey: Self.cleanupKey)
    }
    private func deleteCredential(_ id: String) {
        do {
            try credentials.delete(accountID: id)
            pendingCredentialDeletions.remove(id)
            persistCleanup()
            if pendingCredentialDeletions.isEmpty { cleanupError = nil }
        } catch {
            cleanupError = "旧邮箱的钥匙串条目未删除，请重试清理。" + safeMessage(error)
        }
    }
    func retryCredentialCleanup() async {
        for id in pendingCredentialDeletions.sorted() { deleteCredential(id) }
    }

    func sync(reconnect: Bool = false) async {
        guard let token = begin(.syncing), let client = connection.client else { return }
        defer { finish(token) }
        let id = status?.mailAccountID
        do {
            let new = try await client.syncMail(reconnect: reconnect)
            guard isCurrent(token), status?.mailAccountID == id else { return }
            apply(new)
        } catch {
            guard isCurrent(token), status?.mailAccountID == id else { return }
            await recover(error)
        }
    }

    private func recover(_ error: Error) async {
        errorMessage = safeMessage(error)
        if (error as? MailAPIError)?.needsStatusRefresh == true { await refreshStatus() }
    }
    private func safeMessage(_ error: Error) -> String {
        if let error = error as? MailKeychainError { return error.localizedDescription }
        if let error = error as? MailAPIError { return error.localizedDescription }
        return "邮箱请求未完成，请稍后重试。"
    }
}
