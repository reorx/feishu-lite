import Foundation
import AppKit
import Security
import Testing
import FeishuLiteCore
@testable import FeishuLiteState

@MainActor
private final class FakeMailKeychain: MailCredentialStore {
    let suite = "d1-mail-test-" + UUID().uuidString
    lazy var preferences = UserDefaults(suiteName: suite)!
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    var reads: [String] = []
    var writes: [String] = []
    var deletes: [String] = []
    var readResult: Result<MailSecret, MailKeychainError> = .success(MailSecret("synthetic-only"))
    var writeError: MailKeychainError?
    var deleteError: MailKeychainError?
    func read(accountID: String) throws -> MailSecret {
        reads.append(accountID)
        return try readResult.get()
    }
    func write(_ secret: MailSecret, accountID: String, address: String) throws {
        writes.append(accountID)
        if let writeError { throw writeError }
    }
    func delete(accountID: String) throws {
        deletes.append(accountID)
        if let deleteError { throw deleteError }
    }
}

private final class MailHTTP: URLProtocol {
    static var requests: [URLRequest] = []
    static var account = "00000000-0000-4000-8000-000000000001"
    static var state = "credential_missing"
    static var generation = 1
    static var code = 200
    static var responseOverride: String?
    static var heldPath: String?
    static var held: [() -> Void] = []
    static func reset() { requests = []; state = "credential_missing"; generation = 1; code = 200; responseOverride = nil; heldPath = nil; held = [] }
    static func release() { let callbacks = held; held = []; heldPath = nil; callbacks.forEach { $0() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Task { @MainActor in respond() }
    }
    @MainActor private func respond() {
        Self.requests.append(request)
        let path = request.url!.path
        let body: String
        if path == "/status" { body = "{\"state\":\"logged_out\",\"features\":[\"mail\"]}" }
        else if let override = Self.responseOverride { body = override }
        else if path == "/mail/account", request.httpMethod == "PUT" {
            body = "{\"account\":{\"id\":\"\(Self.account)\",\"address\":\"synthetic@example.invalid\"},\"removed_account_id\":null}"
        } else if path == "/mail/account", request.httpMethod == "DELETE" {
            body = "{\"account\":null,\"removed_account_id\":\"\(Self.account)\"}"
            Self.state = "unconfigured"
        } else if path == "/mail/account/test" { body = "{\"writable\":false,\"supports_idle\":true}" }
        else {
            let account = Self.state == "unconfigured" ? "null" : "\"\(Self.account)\""
            body = "{\"mail_account_id\":\(account),\"address\":\"synthetic@example.invalid\",\"state\":\"\(Self.state)\",\"generation\":\(Self.generation),\"uidvalidity\":77,\"last_sync_at\":123,\"unread_count\":9,\"unread_stale\":true,\"pending\":[],\"error\":null}"
        }
        let code = Self.code
        let finish = {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if Self.heldPath == path { Self.held.append(finish) } else { finish() }
    }
    static func count(_ path: String) -> Int { requests.filter { $0.url!.path == path }.count }
}

@MainActor
private func mailConnection() -> BackendConnection {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MailHTTP.self]
    let connection = BackendConnection()
    connection.client = BackendClient(endpoint: BackendEndpoint(baseURL: URL(string: "http://synthetic.invalid")!, token: "test-only"), session: URLSession(configuration: config))
    return connection
}

@Suite(.serialized)
@MainActor
struct MailIntegrationTests {
    @Test func configurationMissingCredentialRequiresInputWithoutReadingPeer() async {
        MailHTTP.reset()
        let suite = "r4-mail-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            preferences.removePersistentDomain(forName: suite)
            preferences.synchronize()
        }
        let items = RecordingMailSecItems()
        items.seed(service: RecordingMailSecItems.peerService, accountID: MailHTTP.account, value: "peer-only")
        let store = MailKeychain(operations: items.operations)
        let mail = MailState(connection: mailConnection(), credentials: store, externalBackend: false, preferences: preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        await mail.streamConnected()
        await mail.streamConnected()
        #expect(mail.credentialIssue == .notFound)
        #expect(mail.credentialIssue?.errorDescription?.contains("重新输入") == true)
        #expect(MailHTTP.count("/mail/account/credential") == 0)
        #expect(items.queries.map(\.operation) == ["copy"])
        await mail.retryKeychain()
        #expect(mail.credentialIssue == .notFound)
        #expect(items.queries.map(\.operation) == ["copy", "copy"])
        mail.addressInput = "synthetic@example.invalid"
        mail.passwordInput = "reentered-current"
        await mail.saveAccount()
        #expect(mail.credentialIssue == nil)
        #expect(!mail.hasUnsavedCredential)
        #expect(items.value(service: RecordingMailSecItems.currentService, accountID: MailHTTP.account) == "reentered-current")
        #expect(items.value(service: RecordingMailSecItems.peerService, accountID: MailHTTP.account) == "peer-only")
        #expect(items.queries.map(\.operation) == ["copy", "copy", "update", "add"])
        #expect(items.queries.allSatisfy { $0.query[kSecAttrService as String] as? String == RecordingMailSecItems.currentService })
        #expect(items.queries.allSatisfy { $0.query[kSecAttrAccount as String] as? String == MailHTTP.account })
    }

    @Test(arguments: [true, false])
    func configurationDeferredDeletionAfterReconstructionOnlyCleansCurrentService(_ currentItemExists: Bool) async {
        MailHTTP.reset()
        let suite = "r4-mail-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            preferences.removePersistentDomain(forName: suite)
            preferences.synchronize()
        }
        let items = RecordingMailSecItems()
        let canary = UUID().uuidString
        for service in [RecordingMailSecItems.currentService, RecordingMailSecItems.peerService] {
            if currentItemExists || service == RecordingMailSecItems.peerService {
                items.seed(service: service, accountID: MailHTTP.account, value: "synthetic-secret")
            }
            items.seed(service: service, accountID: canary, value: "canary")
        }
        let store = MailKeychain(operations: items.operations)
        let mail = MailState(connection: mailConnection(), credentials: store, externalBackend: false, preferences: preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        items.deleteStatus = errSecAuthFailed
        await mail.removeAccount()
        #expect(mail.pendingCredentialDeletions == [MailHTTP.account])
        #expect(items.value(service: RecordingMailSecItems.currentService, accountID: MailHTTP.account) == (currentItemExists ? "synthetic-secret" : nil))
        let rebuilt = MailState(connection: mailConnection(), credentials: MailKeychain(operations: items.operations), externalBackend: false, preferences: preferences)
        #expect(rebuilt.pendingCredentialDeletions == [MailHTTP.account])
        #expect(!String(describing: preferences.persistentDomain(forName: suite)).contains("synthetic-secret"))
        items.deleteStatus = errSecSuccess
        await rebuilt.retryCredentialCleanup()
        #expect(rebuilt.pendingCredentialDeletions.isEmpty)
        #expect(items.value(service: RecordingMailSecItems.currentService, accountID: MailHTTP.account) == nil)
        #expect(items.value(service: RecordingMailSecItems.peerService, accountID: MailHTTP.account) == "synthetic-secret")
        #expect(items.value(service: RecordingMailSecItems.currentService, accountID: canary) == "canary")
        #expect(items.value(service: RecordingMailSecItems.peerService, accountID: canary) == "canary")
        let again = MailState(connection: mailConnection(), credentials: store, externalBackend: false, preferences: preferences)
        #expect(again.pendingCredentialDeletions.isEmpty)
        #expect(items.queries.map(\.operation) == ["copy", "delete", "delete"])
        #expect(items.queries.allSatisfy { $0.query[kSecAttrService as String] as? String == RecordingMailSecItems.currentService })
        #expect(items.queries.allSatisfy { $0.query[kSecAttrAccount as String] as? String == MailHTTP.account })
    }

    @Test func readyAndSSEAreBothRequiredAndRestartReusesMemory() async {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        #expect(keychain.reads == [MailHTTP.account])
        #expect(MailHTTP.count("/mail/account/credential") == 0)
        await mail.streamConnected()
        #expect(MailHTTP.count("/mail/account/credential") == 1)
        await mail.streamConnected()
        #expect(MailHTTP.count("/mail/account/credential") == 1)
        mail.backendChanged(ready: false)
        mail.backendChanged(ready: true)
        MailHTTP.generation = 0
        await mail.setCapability(features: ["mail"])
        await mail.streamConnected()
        #expect(keychain.reads.count == 1)
        #expect(MailHTTP.count("/mail/account/credential") == 2)
        #expect(mail.status?.generation == 0)
    }

    @Test func unknownOldAndExternalBackendNeverReadKeychain() async {
        for external in [false, true] {
            MailHTTP.reset()
            let keychain = FakeMailKeychain()
            defer {
                keychain.preferences.removePersistentDomain(forName: keychain.suite)
                keychain.preferences.synchronize()
            }
            let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: external, preferences: keychain.preferences)
            mail.backendChanged(ready: true)
            await mail.streamConnected()
            #expect(keychain.reads.isEmpty)
            await mail.setCapability(features: [])
            #expect(MailHTTP.requests.isEmpty)
            await mail.setCapability(features: ["mail"])
            if external { #expect(keychain.reads.isEmpty); #expect(MailHTTP.count("/mail/account/credential") == 0) }
        }
    }

    @Test(arguments: [MailKeychainError.notFound, .denied, .locked])
    func credentialFailuresOnlyRetryWhenExplicit(_ failure: MailKeychainError) async {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        keychain.readResult = .failure(failure)
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        await mail.streamConnected()
        await mail.streamConnected()
        #expect(mail.credentialIssue == failure)
        #expect(keychain.reads.count == 1)
        #expect(MailHTTP.count("/mail/account/credential") == 0)
        keychain.readResult = .success(MailSecret("replacement"))
        await mail.retryKeychain()
        #expect(keychain.reads.count == 2)
        #expect(MailHTTP.count("/mail/account/credential") == 1)
    }

    @Test func testDoesNotSaveAndWriteDeleteFailuresRemainRetryable() async {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        mail.addressInput = "synthetic@example.invalid"
        mail.passwordInput = "synthetic-secret"
        await mail.testConnection()
        #expect(mail.connectionTest?.writable == false)
        #expect(keychain.writes.isEmpty)
        keychain.writeError = .locked
        await mail.saveAccount()
        #expect(mail.hasUnsavedCredential)
        #expect(mail.passwordInput.isEmpty)
        keychain.writeError = nil
        await mail.retryCredentialSave()
        #expect(!mail.hasUnsavedCredential)
        keychain.deleteError = .denied
        await mail.removeAccount()
        #expect(mail.pendingCredentialDeletions == [MailHTTP.account])
        #expect(mail.status?.state == .unconfigured)
        keychain.deleteError = nil
        await mail.retryCredentialCleanup()
        #expect(mail.pendingCredentialDeletions.isEmpty)
        #expect(MailHTTP.count("/mail/messages") == 0)
        #expect(MailHTTP.count("/mail/notifications/ack") == 0)
    }
}

@MainActor
private func waitForMail(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("邮箱隔离请求未在限定时间收敛")
}

@MainActor
private final class MailWindowRecorder: AppWindows {
    var window: NSWindow? { nil }
    var isShowingContent: Bool { false }
    func show() {}
}

extension MailIntegrationTests {
    @Test func timedOutAccountReplacementUsesConfirmedStatusToTrackOldCredentialCleanup() async throws {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        keychain.deleteError = .denied
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        mail.addressInput = "replacement@example.invalid"
        mail.passwordInput = "synthetic-timeout-secret"
        MailHTTP.code = 504
        MailHTTP.responseOverride = "{\"domain\":\"mail\",\"code\":\"request_timeout\"}"
        MailHTTP.heldPath = "/mail/account"
        let saving = Task { await mail.saveAccount() }
        try await waitForMail { !MailHTTP.held.isEmpty }
        let replacement = "00000000-0000-4000-8000-000000000002"
        MailHTTP.code = 200
        MailHTTP.responseOverride = "{\"mail_account_id\":\"\(replacement)\",\"address\":\"replacement@example.invalid\",\"state\":\"online\",\"generation\":2,\"uidvalidity\":88,\"last_sync_at\":null,\"unread_count\":4,\"unread_stale\":false,\"pending\":[],\"error\":null}"
        MailHTTP.release()
        await saving.value
        #expect(mail.status?.mailAccountID == replacement)
        #expect(keychain.deletes == [MailHTTP.account])
        #expect(mail.pendingCredentialDeletions == [MailHTTP.account])
        #expect(keychain.writes.isEmpty)
    }

    @Test func configureTimeoutRecoversCommittedBackendStateWithoutClaimingKeychainSave() async throws {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        mail.addressInput = "synthetic@example.invalid"
        mail.passwordInput = "synthetic-timeout-secret"
        MailHTTP.code = 504
        MailHTTP.responseOverride = "{\"domain\":\"mail\",\"code\":\"request_timeout\"}"
        MailHTTP.heldPath = "/mail/account"
        let saving = Task { await mail.saveAccount() }
        try await waitForMail { !MailHTTP.held.isEmpty }
        MailHTTP.code = 200
        MailHTTP.responseOverride = nil
        MailHTTP.state = "online"
        MailHTTP.generation = 2
        MailHTTP.release()
        await saving.value
        #expect(MailHTTP.count("/mail/status") == 2)
        #expect(mail.status?.state == .online)
        #expect(mail.status?.generation == 2)
        #expect(keychain.writes.isEmpty)
        #expect(mail.errorMessage != nil)
    }

    @Test func sameAccountSavePreservesUnreadSnapshotWhenStatusRefreshFails() async throws {
        MailHTTP.reset()
        MailHTTP.state = "online"
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        #expect(mail.status?.unreadCount == 9)
        mail.addressInput = "synthetic@example.invalid"
        mail.passwordInput = "replacement-secret"
        MailHTTP.heldPath = "/mail/account"
        let saving = Task { await mail.saveAccount() }
        try await waitForMail { !MailHTTP.held.isEmpty }
        MailHTTP.code = 503
        MailHTTP.responseOverride = "{\"domain\":\"mail\",\"code\":\"offline\"}"
        MailHTTP.release()
        await saving.value
        #expect(mail.status?.state == .connecting)
        #expect(mail.status?.unreadCount == 9)
        #expect(mail.status?.lastSyncAt == 123)
        #expect(mail.errorMessage != nil)
    }

    @Test func deletionTrackingSurvivesStateReconstructionAndContainsNoPassword() async {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        keychain.deleteError = .denied
        await mail.removeAccount()
        #expect(mail.pendingCredentialDeletions == [MailHTTP.account])
        let rebuilt = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        #expect(rebuilt.pendingCredentialDeletions == [MailHTTP.account])
        #expect(!rebuilt.hasUnsavedCredential)
        #expect(rebuilt.passwordInput.isEmpty)
        #expect(!String(describing: keychain.preferences.persistentDomain(forName: keychain.suite)).contains("synthetic-only"))
        keychain.deleteError = nil
        await rebuilt.retryCredentialCleanup()
        #expect(keychain.deletes == [MailHTTP.account, MailHTTP.account])
        #expect(rebuilt.pendingCredentialDeletions.isEmpty)
        let again = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        #expect(again.pendingCredentialDeletions.isEmpty)
    }

    @Test func failedWriteCannotRestoreMemorySecretAfterAppRestart() async {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        keychain.readResult = .failure(.notFound)
        keychain.writeError = .locked
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        mail.addressInput = "synthetic@example.invalid"
        mail.passwordInput = "write-failed-secret"
        await mail.saveAccount()
        #expect(mail.hasUnsavedCredential)
        let rebuilt = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        rebuilt.backendChanged(ready: true)
        await rebuilt.setCapability(features: ["mail"])
        await rebuilt.streamConnected()
        #expect(rebuilt.credentialIssue == .notFound)
        #expect(MailHTTP.count("/mail/account/credential") == 0)
        #expect(!String(describing: keychain.preferences.persistentDomain(forName: keychain.suite)).contains("write-failed-secret"))
        #expect(Mirror(reflecting: mail).children.isEmpty)
    }

    @Test func actualAppDistributesMailIndependentOfLoggedOutChatAndKeepsBadgePending() async throws {
        _ = NSApplication.shared
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        var badges: [Int] = []
        let app = AppState(supervisor: BackendSupervisor(config: BackendConfig(uvPath: "", backendDir: "", externalEndpoint: nil, homeOverride: nil)), notifications: NotificationService(badgeWriter: { badges.append($0) }, notificationCenter: NotificationCenterRecorder()), windows: MailWindowRecorder(), preferences: keychain.preferences, credentials: keychain, makeClient: { _ in mailConnection().client! })
        app.activeModule = .email
        let endpoint = BackendEndpoint(baseURL: URL(string: "http://synthetic.invalid")!, token: "test-only")
        app.backendStateChanged(.ready(endpoint), startEventLoop: false)
        await app.refreshAfterEventStreamConnected()
        #expect(app.messages.status?.state == .loggedOut)
        #expect(app.messages.login.phase == .idle)
        #expect(keychain.reads.count == 1)
        #expect(MailHTTP.count("/mail/account/credential") == 1)
        #expect(app.unreadCounts.email == 9)
        #expect(badges.last == 9)
        let batch = #"{"id":"batch-test","account_id":"00000000-0000-4000-8000-000000000001","folder_id":"INBOX","uidvalidity":77,"mode":"summary","items":[]}"#
        let eventData = "{\"type\":\"mail.status\",\"account_id\":\"\(MailHTTP.account)\",\"generation\":2,\"folder_id\":\"INBOX\",\"uidvalidity\":77,\"status\":{\"mail_account_id\":\"\(MailHTTP.account)\",\"address\":\"synthetic@example.invalid\",\"state\":\"auth_failed\",\"generation\":2,\"uidvalidity\":77,\"last_sync_at\":123,\"unread_count\":9,\"unread_stale\":true,\"pending\":[\(batch)],\"error\":\"authentication_failed\"},\"notification\":null,\"read_ids\":[],\"deleted_ids\":[],\"reset\":false}"
        let event = try BackendJSON.decoder.decode(MailEvent.self, from: Data(eventData.utf8))
        await app.handle(.mail(event))
        #expect(app.mail.pending.count == 1)
        #expect(app.unreadCounts.email == 9)
        await app.refreshAfterEventStreamConnected()
        #expect(MailHTTP.count("/mail/account/credential") == 1)
        #expect(MailHTTP.count("/mail/notifications/ack") == 0)
        #expect(MailHTTP.requests.allSatisfy { !$0.url!.path.hasSuffix("/read") })
        app.open(.email(accountID: MailHTTP.account, folderID: "INBOX", messageID: "not-yet-loaded"))
        #expect(app.viewingContext.selectedMail == nil)
        app.backendStateChanged(.stopped, startEventLoop: false)
        #expect(app.unreadCounts.email == 9)
        app.messages.login.end()
    }

    @Test func lateTestAndOldBackendResponseCannotOverwriteNewerInputOrIdentity() async throws {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        mail.addressInput = "synthetic@example.invalid"
        mail.passwordInput = "test-secret"
        MailHTTP.heldPath = "/mail/account/test"
        let test = Task { await mail.testConnection() }
        try await waitForMail { !MailHTTP.held.isEmpty }
        await mail.saveAccount() // 重复按钮期间不能多次提交。
        #expect(MailHTTP.count("/mail/account") == 0)
        mail.addressInput = "replacement@example.invalid"
        MailHTTP.release()
        await test.value
        #expect(mail.connectionTest == nil)
        #expect(mail.operation == nil)
        MailHTTP.heldPath = "/mail/status"
        let old = Task { await mail.refreshStatus() }
        try await waitForMail { !MailHTTP.held.isEmpty }
        mail.backendChanged(ready: false)
        mail.backendChanged(ready: true)
        MailHTTP.release()
        await old.value
        #expect(mail.capability == .unknown)
        #expect(mail.status?.generation == 0)
    }

    @Test func updatedGenerationRejectsLaterOlderStatusAndAccountSwitchRejectsOldEvents() async throws {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        let raw = "{\"type\":\"mail.updated\",\"account_id\":\"\(MailHTTP.account)\",\"generation\":3,\"folder_id\":\"INBOX\",\"uidvalidity\":77,\"status\":null,\"notification\":null,\"read_ids\":[],\"deleted_ids\":[],\"reset\":false}"
        await mail.handle(try BackendJSON.decoder.decode(MailEvent.self, from: Data(raw.utf8)))
        MailHTTP.generation = 2
        MailHTTP.state = "online"
        await mail.refreshStatus()
        #expect(mail.status?.state == .credentialMissing)
    }
}

extension MailIntegrationTests {
    @Test func mailSnapshotWaitDoesNotBlockActualSSEDispatchOfChatStatus() async throws {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let app = AppState(supervisor: BackendSupervisor(config: BackendConfig(uvPath: "", backendDir: "", externalEndpoint: nil, homeOverride: nil)), notifications: NotificationService(badgeWriter: { _ in }, notificationCenter: NotificationCenterRecorder()), windows: MailWindowRecorder(), preferences: keychain.preferences, credentials: keychain, makeClient: { _ in mailConnection().client! })
        app.activeModule = .email
        app.backendStateChanged(.ready(BackendEndpoint(baseURL: URL(string: "http://synthetic.invalid")!, token: "test-only")), startEventLoop: false)
        MailHTTP.heldPath = "/mail/status"
        app.receiveStreamEvent(.status(BackendStatus(state: .loggedOut, features: ["mail"])))
        try await waitForMail { !MailHTTP.held.isEmpty }
        app.receiveStreamEvent(.status(BackendStatus(state: .connecting, features: ["mail"])))
        try await waitForMail { app.messages.status?.state == .connecting }
        #expect(!MailHTTP.held.isEmpty)
        MailHTTP.release()
        app.backendStateChanged(.stopped, startEventLoop: false)
        app.messages.login.end()
    }
}

private func mailEvent(status: MailStatus, type: String = "mail.status") throws -> MailEvent {
    let statusObject = try JSONSerialization.jsonObject(with: BackendJSON.encoder.encode(status))
    let raw: [String: Any] = ["type": type, "account_id": status.mailAccountID as Any? ?? NSNull(), "generation": status.generation,
                              "folder_id": "INBOX", "uidvalidity": status.uidvalidity as Any? ?? NSNull(), "status": statusObject,
                              "notification": NSNull(), "read_ids": [], "deleted_ids": [], "reset": false]
    return try BackendJSON.decoder.decode(MailEvent.self, from: JSONSerialization.data(withJSONObject: raw))
}

extension MailIntegrationTests {
    @Test func sustainedMailEventsWithSlowHTTPHaveBoundedWorkAndOrderedAccountGeneration() async throws {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let app = AppState(supervisor: BackendSupervisor(config: BackendConfig(uvPath: "", backendDir: "", externalEndpoint: nil, homeOverride: nil)), notifications: NotificationService(badgeWriter: { _ in }, notificationCenter: NotificationCenterRecorder()), windows: MailWindowRecorder(), preferences: keychain.preferences, credentials: keychain, makeClient: { _ in mailConnection().client! })
        app.activeModule = .email
        app.backendStateChanged(.ready(BackendEndpoint(baseURL: URL(string: "http://synthetic.invalid")!, token: "test-only")), startEventLoop: false)
        MailHTTP.heldPath = "/mail/status"
        app.receiveStreamEvent(.status(BackendStatus(state: .loggedOut, features: ["mail"])))
        try await waitForMail { !MailHTTP.held.isEmpty }
        for generation in 1...500 {
            let snapshot = MailStatus(mailAccountID: MailHTTP.account, address: "synthetic@example.invalid", state: .online,
                                      generation: generation, uidvalidity: 77, unreadCount: generation)
            app.receiveStreamEvent(.mail(try mailEvent(status: snapshot)))
            #expect(app.activeEventWorkCount <= 2)
        }
        let replacement = "00000000-0000-4000-8000-000000000002"
        app.receiveStreamEvent(.mail(try mailEvent(status: MailStatus(mailAccountID: replacement, address: "replacement@example.invalid", state: .online, generation: 501, uidvalidity: 88, unreadCount: 7))))
        app.receiveStreamEvent(.mail(try mailEvent(status: MailStatus(mailAccountID: MailHTTP.account, state: .online, generation: 502, uidvalidity: 77, unreadCount: 999))))
        #expect(app.mail.status?.mailAccountID == replacement)
        #expect(app.unreadCounts.email == 7)
        app.receiveStreamEvent(.status(BackendStatus(state: .connecting, features: ["mail"])))
        app.receiveStreamEvent(.status(BackendStatus(state: .reconnecting, features: ["mail"])))
        #expect(app.messages.status?.state == .reconnecting)
        MailHTTP.release()
        try await waitForMail { app.activeEventWorkCount == 0 }
        #expect(MailHTTP.count("/mail/status") <= 2)
        #expect(app.mail.status?.mailAccountID == replacement)
        #expect(app.unreadCounts.email == 7)
        app.backendStateChanged(.stopped, startEventLoop: false)
        app.messages.login.end()
    }
}

extension MailIntegrationTests {
    @Test func productionStreamConsumerMaintainsChatOrderDuringHeldMailStatusAndEndsCleanly() async throws {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let app = AppState(supervisor: BackendSupervisor(config: BackendConfig(uvPath: "", backendDir: "", externalEndpoint: nil, homeOverride: nil)), notifications: NotificationService(badgeWriter: { _ in }, notificationCenter: NotificationCenterRecorder()), windows: MailWindowRecorder(), preferences: keychain.preferences, credentials: keychain, makeClient: { _ in mailConnection().client! })
        app.activeModule = .email
        app.backendStateChanged(.ready(BackendEndpoint(baseURL: URL(string: "http://synthetic.invalid")!, token: "test-only")), startEventLoop: false)
        MailHTTP.heldPath = "/mail/status"
        let (stream, continuation) = AsyncThrowingStream<BackendEvent, Error>.makeStream()
        let consumer = Task { try await app.consumeEventStream(stream) }
        continuation.yield(.status(BackendStatus(state: .loggedOut, features: ["mail"])))
        try await waitForMail { !MailHTTP.held.isEmpty }
        var receivedMailGenerations: [Int] = []
        app.mail.onEvent = { receivedMailGenerations.append($0.generation) }
        for generation in 1...300 {
            let snapshot = MailStatus(mailAccountID: MailHTTP.account, state: .online, generation: generation, uidvalidity: 77, unreadCount: generation)
            continuation.yield(.mail(try mailEvent(status: snapshot)))
            let update = "{\"type\":\"mail.updated\",\"account_id\":\"\(MailHTTP.account)\",\"generation\":\(generation),\"folder_id\":\"INBOX\",\"uidvalidity\":77,\"status\":null,\"notification\":null,\"read_ids\":[],\"deleted_ids\":[],\"reset\":false}"
            continuation.yield(.mail(try BackendJSON.decoder.decode(MailEvent.self, from: Data(update.utf8))))
            continuation.yield(.status(BackendStatus(state: .connecting, features: ["mail"])))
            continuation.yield(.status(BackendStatus(state: .reconnecting, features: ["mail"])))
        }
        continuation.yield(.status(BackendStatus(state: .loggedOut, features: ["mail"])))
        continuation.finish()
        try await consumer.value
        #expect(app.messages.status?.state == .loggedOut)
        #expect(receivedMailGenerations == (1...300).flatMap { [$0, $0] })
        #expect(app.mail.status?.generation == 300)
        #expect(app.unreadCounts.email == 300)
        #expect(app.activeEventWorkCount <= 2)
        #expect(MailHTTP.count("/mail/status") <= 2)
        MailHTTP.release()
        try await waitForMail { app.activeEventWorkCount == 0 }
        #expect(app.mail.status?.generation == 300)
        app.backendStateChanged(.stopped, startEventLoop: false)
        #expect(app.activeEventWorkCount == 0)
        #expect(app.messages.login.phase == .idle)
    }

    @Test func lateConfigureFromOldBackendCannotSaveSecretOrReplaceAccount() async throws {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let mail = MailState(connection: mailConnection(), credentials: keychain, externalBackend: false, preferences: keychain.preferences)
        mail.backendChanged(ready: true)
        await mail.setCapability(features: ["mail"])
        mail.addressInput = "synthetic@example.invalid"
        mail.passwordInput = "synthetic-save"
        MailHTTP.heldPath = "/mail/account"
        let saving = Task { await mail.saveAccount() }
        try await waitForMail { !MailHTTP.held.isEmpty }
        await mail.saveAccount()
        #expect(MailHTTP.count("/mail/account") == 1)
        mail.backendChanged(ready: false)
        MailHTTP.release()
        await saving.value
        #expect(keychain.writes.isEmpty)
        #expect(mail.operation == nil)
        #expect(mail.status?.generation == 0)
    }

    @Test func accountReplacementClearsOnlyOldKeychainMemorySelectionAndRoute() async throws {
        MailHTTP.reset()
        let keychain = FakeMailKeychain()
        defer {
            keychain.preferences.removePersistentDomain(forName: keychain.suite)
            keychain.preferences.synchronize()
        }
        let app = AppState(supervisor: BackendSupervisor(config: BackendConfig(uvPath: "", backendDir: "", externalEndpoint: nil, homeOverride: nil)), notifications: NotificationService(badgeWriter: { _ in }, notificationCenter: NotificationCenterRecorder()), windows: MailWindowRecorder(), preferences: keychain.preferences, credentials: keychain, makeClient: { _ in mailConnection().client! })
        app.activeModule = .email
        app.backendStateChanged(.ready(BackendEndpoint(baseURL: URL(string: "http://synthetic.invalid")!, token: "test-only")), startEventLoop: false)
        await app.refreshAfterEventStreamConnected()
        let old = MailHTTP.account
        let replacement = "00000000-0000-4000-8000-000000000002"
        app.open(.email(accountID: old, folderID: "INBOX", messageID: "old-id"))
        app.mail.selectedMessageID = "old-id"
        app.mail.listScrollAnchor = "old-id"
        app.mail.addressInput = "replacement@example.invalid"
        app.mail.passwordInput = "replacement-secret"
        MailHTTP.responseOverride = "{\"account\":{\"id\":\"\(replacement)\",\"address\":\"replacement@example.invalid\"},\"removed_account_id\":\"\(old)\"}"
        // status 刷新仍返回同一 override，安全解码失败不回滚已确认的配置/钥匙串。
        await app.mail.saveAccount()
        #expect(keychain.deletes == [old])
        #expect(keychain.writes == [replacement])
        #expect(app.mail.status?.mailAccountID == replacement)
        #expect(app.pendingMailRoute == nil)
        #expect(app.mail.selectedMessageID == nil)
        #expect(app.mail.listScrollAnchor == nil)
        #expect(app.unreadCounts.email == 0)
        #expect(app.mail.passwordInput.isEmpty)
        #expect(MailHTTP.count("/mail/notifications/ack") == 0)
        app.backendStateChanged(.stopped, startEventLoop: false)
    }

    @Test func typedClientEncodesQueriesPathsAndSeparatesMailErrorsFromLocalToken() async throws {
        MailHTTP.reset()
        let client = mailConnection().client!
        MailHTTP.responseOverride = #"{"items":[],"next_cursor":null}"#
        _ = try await client.mailMessages(folder: "目录/子目录 +?&", cursor: "opaque/+?&")
        let request = try #require(MailHTTP.requests.last)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first(where: { $0.name == "folder" })?.value == "目录/子目录 +?&")
        #expect(query.first(where: { $0.name == "cursor" })?.value == "opaque/+?&")
        #expect(request.timeoutInterval == 35)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only")
        MailHTTP.responseOverride = #"{"kind":"plain","content":"synthetic"}"#
        _ = try await client.mailBody(id: "opaque/with?query#fragment")
        #expect(MailHTTP.requests.last?.url?.query == nil)
        #expect(MailHTTP.requests.last?.url?.fragment == nil)
        #expect(MailHTTP.requests.last?.url?.absoluteString.contains("opaque%2Fwith%3Fquery%23fragment") == true)
        for status in [401, 403, 409, 500] {
            MailHTTP.code = status
            MailHTTP.responseOverride = #"{"domain":"mail","code":"authentication_failed","detail":"logged_out","password":"synthetic-secret"}"#
            do {
                _ = try await client.injectMailCredential(accountID: MailHTTP.account, password: MailSecret("synthetic-secret"))
                Issue.record("请求应失败")
            } catch let error as MailAPIError {
                #expect(error.isLocalTokenFailure == (status == 401))
                #expect(!error.localizedDescription.contains("synthetic-secret"))
            } catch { Issue.record("邮件错误不应进入聊天错误域") }
        }
    }
}
