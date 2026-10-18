import AppKit
import Foundation
import UserNotifications
import Testing
import FeishuLiteCore
@testable import FeishuLiteState

@MainActor final class NotificationCenterRecorder: LocalNotificationCenter {
    var permission: NotificationPermission = .allowed
    var entries: [LocalNotification] = []
    var posts: [LocalNotification] = []
    var removed: [String] = []
    var failureAt: Int?
    var holdAdd = false
    var heldAdd: CheckedContinuation<Void, Never>?
    var holdQuery = false
    var heldQuery: CheckedContinuation<Void, Never>?
    func authorization() async -> NotificationPermission { permission }
    func notifications() async -> [LocalNotification] {
        let snapshot = entries
        if holdQuery { await withCheckedContinuation { heldQuery = $0 } }
        return snapshot
    }
    func add(_ notification: LocalNotification) async throws {
        posts.append(notification)
        if holdAdd { await withCheckedContinuation { heldAdd = $0 } }
        if posts.count == failureAt { throw MailAPIError(status:503,code:"offline") }
        entries.removeAll { $0.id == notification.id }; entries.append(notification)
    }
    func remove(_ ids: [String]) {
        removed += ids; entries.removeAll { ids.contains($0.id) }
    }
}
@MainActor private final class NotificationCredentials: MailCredentialStore {
    var reads = 0
    func read(accountID: String) throws -> MailSecret { reads += 1; throw MailKeychainError.notFound }
    func write(_ secret: MailSecret, accountID: String, address: String) throws {}
    func delete(accountID: String) throws {}
}
@MainActor private final class NotificationWindows: AppWindows {
    var window: NSWindow? { nil }
    var isShowingContent = false
    func show() { isShowingContent = true }
}

private final class NotificationHTTP: URLProtocol {
    static var account = "00000000-0000-4000-8000-0000000000e0"
    static var validity = 77
    static var generation = 1
    static var state = "online"
    static var batches: [[String: Any]] = []
    static var requests: [URLRequest] = []
    static var ackCode = 200
    static var keepPendingAfterAck = false
    static var unseen: Set<Int> = [1,2,3,4]
    static var missing: Set<Int> = []
    static var holdPath: String?
    static var held: [() -> Void] = []
    static func reset() {
        account = "00000000-0000-4000-8000-0000000000e0"; validity = 77; generation = 1
        state = "online"; batches = []; requests = []; ackCode = 200; keepPendingAfterAck = false
        unseen = [1,2,3,4]; missing = []; holdPath = nil; held = []
    }
    static func release() { let callbacks = held; held = []; holdPath = nil; callbacks.forEach { $0() } }
    static func count(_ suffix: String) -> Int { requests.filter { $0.url!.path.hasSuffix(suffix) }.count }
    static func row(_ uid: Int) -> [String: Any] {
        ["id":"synthetic-mail-\(uid)","key":["account_id":account,"folder_id":"INBOX","uidvalidity":validity,"uid":uid],
         "subject":"合成主题 \(uid)","sender":[["name":"合成发件人","address":"synthetic@example.invalid"]],
         "to":[["name":"合成发件人","address":"synthetic@example.invalid"]],"cc":[],"date":"","message_id":"",
         "received_at":123,"size":100,"flags":unseen.contains(uid) ? [] : ["\\Seen"],"unread":unseen.contains(uid),
         "attachments":[],"body_part":NSNull(),"error":NSNull()]
    }
    static func batch(_ uids: [Int], mode: String = "individual", id: String = "stable-batch") -> [String: Any] {
        ["id":id,"account_id":account,"folder_id":"INBOX","uidvalidity":validity,"mode":mode,"items":uids.map(row)]
    }
    static func snapshot() -> [String: Any] {
        ["mail_account_id":state == "unconfigured" ? NSNull() : account,"address":"synthetic@example.invalid",
         "state":state,"generation":generation,"uidvalidity":validity,"last_sync_at":123,"unread_count":state == "unconfigured" ? 0 : 321,
         "unread_stale":state != "online","pending":batches,"error":NSNull()]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { Task { @MainActor in respond() } }
    @MainActor private func respond() {
        Self.requests.append(request)
        let path = request.url!.path
        var code = 200
        var payload: Any = Self.snapshot()
        if path == "/status" { payload = ["state":"logged_out","features":["mail"]] }
        else if path == "/mail/folders" { payload = [] }
        else if path == "/mail/messages" { payload = ["items":[],"next_cursor":NSNull()] }
        else if path == "/mail/notifications/ack" {
            code = Self.ackCode
            if code == 200 {
                let body = try! JSONSerialization.jsonObject(with: request.httpBody ?? Self.readBody(request)) as! [String: Any]
                if !Self.keepPendingAfterAck {
                    Self.batches.removeAll { $0["id"] as? String == body["batch_id"] as? String }
                }
                payload = Self.snapshot()
            }
        } else if path.hasSuffix("/summary") {
            let uid = Int(path.split(separator:"/").dropLast().last!.split(separator:"-").last!)!
            if Self.missing.contains(uid) { code = 404 }
            payload = Self.row(uid)
        } else if path.hasSuffix("/read") {
            let uid = Int(path.split(separator:"/").dropLast().last!.split(separator:"-").last!)!
            Self.unseen.remove(uid)
            payload = ["read_ids":["synthetic-mail-\(uid)"]]
        } else if path == "/mail/account", request.httpMethod == "DELETE" {
            Self.state = "unconfigured"; Self.batches = []
            payload = ["account":NSNull(),"removed_account_id":Self.account]
        } else if path.contains("/mail/messages/") { payload = ["kind":"plain","content":"合成正文"] }
        if code != 200 { payload = ["domain":"mail","code":code == 404 ? "message_missing" : "request_timeout"] }
        let data = try! JSONSerialization.data(withJSONObject:payload)
        let finish = {
            self.client?.urlProtocol(self,didReceive:HTTPURLResponse(url:self.request.url!,statusCode:code,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self,didLoad:data); self.client?.urlProtocolDidFinishLoading(self)
        }
        if Self.holdPath == path { Self.held.append(finish) } else { finish() }
    }
    private static func readBody(_ request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating:0,count:1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer,maxLength:buffer.count)
            if count <= 0 { break }; data.append(buffer,count:count)
        }
        return data
    }
}

@MainActor private final class NotificationHarness {
    let suite = "e-notifications-" + UUID().uuidString
    let preferences: UserDefaults
    let center: NotificationCenterRecorder
    let credentials = NotificationCredentials()
    let windows = NotificationWindows()
    var badges: [Int] = []
    var app: AppState!
    init(center: NotificationCenterRecorder? = nil, preferences: UserDefaults? = nil) {
        self.center = center ?? NotificationCenterRecorder(); self.preferences = preferences ?? UserDefaults(suiteName:suite)!
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NotificationHTTP.self]
        let client = BackendClient(endpoint:BackendEndpoint(baseURL:URL(string:"http://synthetic.invalid")!,token:"synthetic"),session:URLSession(configuration:config))
        let notifications = NotificationService(badgeWriter:{ [weak self] in self?.badges.append($0) }, notificationCenter:self.center)
        app = AppState(supervisor:BackendSupervisor(config:BackendConfig(uvPath:"",backendDir:"",externalEndpoint:nil,homeOverride:nil)),
                       notifications:notifications, windows:windows, preferences:self.preferences, credentials:credentials, makeClient:{ _ in client })
        app.backendStateChanged(.ready(BackendEndpoint(baseURL:URL(string:"http://synthetic.invalid")!,token:"synthetic")), startEventLoop:false)
    }
    func ready() async {
        await app.mail.setCapability(features:["mail"])
        await app.mailNotifications.waitForWork()
    }
    func close(removePreferences: Bool = true) {
        app.shutdown(); NotificationHTTP.release()
        center.holdAdd = false; center.heldAdd?.resume(); center.heldAdd = nil
        center.holdQuery = false; center.heldQuery?.resume(); center.heldQuery = nil
        if removePreferences { preferences.removePersistentDomain(forName:suite); preferences.synchronize() }
    }
}

@Suite(.serialized) @MainActor struct MailNotificationTests {
    @Test(arguments:[200, 504])
    func ackBackoffSurvivesRepeatedTriggersAndLaterRecovers(code: Int) async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        NotificationHTTP.ackCode = code; NotificationHTTP.keepPendingAfterAck = true
        let h = NotificationHarness(); defer { h.close() }
        var now: TimeInterval = 0
        h.app.mailNotifications.ackClock = { now }
        await h.ready()
        for _ in 0..<30 {
            h.app.mailNotifications.request()
            await h.app.mailNotifications.waitForWork()
        }
        #expect(NotificationHTTP.count("/ack") == 1)
        #expect(h.app.mailNotifications.lastFailure != nil)
        now = 1
        h.app.mailNotifications.request(); await h.app.mailNotifications.waitForWork()
        #expect(NotificationHTTP.count("/ack") == 2)
        now = 2.99
        h.app.mailNotifications.request(); await h.app.mailNotifications.waitForWork()
        #expect(NotificationHTTP.count("/ack") == 2)
        // A different batch must not wait for the old one's backoff.
        NotificationHTTP.batches.append(NotificationHTTP.batch([2],id:"new-batch"))
        await h.app.mail.refreshStatus(); await h.app.mailNotifications.waitForWork()
        #expect(NotificationHTTP.count("/ack") == 3)
        #expect(h.center.posts.count == 2)
        NotificationHTTP.ackCode = 200; NotificationHTTP.keepPendingAfterAck = false
        now = 4
        h.app.mailNotifications.request(); await h.app.mailNotifications.waitForWork()
        #expect(h.app.mail.pending.isEmpty)
        #expect(NotificationHTTP.count("/ack") == 5)
        #expect(h.center.posts.count == 2)
        #expect(h.app.mailNotifications.lastFailure == nil)
    }

    @Test func unchangedPendingAfterSuccessfulAckSettlesWithoutARequestLoop() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        NotificationHTTP.keepPendingAfterAck = true
        let h = NotificationHarness(); defer { h.close() }
        await h.app.mail.setCapability(features:["mail"])
        // Do not await waitForWork on the broken code: its loop never settles.
        try await Task.sleep(for:.milliseconds(300))
        let first = NotificationHTTP.count("/ack")
        try await Task.sleep(for:.milliseconds(300))
        let second = NotificationHTTP.count("/ack")
        #expect(first == 1)
        #expect(second == first)
        #expect(h.app.mailNotifications.workCount == 0)
        #expect(h.app.mail.pending.count == 1)
        #expect(h.center.posts.count == 1)
        let data = try #require(h.preferences.data(forKey:"mail-notification-receipts-v1"))
        let saved = try JSONDecoder().decode([String:MailNotificationReceipt].self,from:data)
        #expect(saved.values.allSatisfy { $0.handled && !$0.acknowledged })
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for:.milliseconds(5)) }
        Issue.record("等待合成通知操作超时")
    }
    private func event(_ kind: String, notification: [String:Any]? = nil, read: [String] = [], deleted: [String] = [], reset: Bool = false) throws -> BackendEvent {
        var payload: [String:Any] = ["type":kind,"account_id":NotificationHTTP.account,"generation":NotificationHTTP.generation,
                                   "folder_id":"INBOX","uidvalidity":NotificationHTTP.validity,"read_ids":read,"deleted_ids":deleted,"reset":reset]
        if let notification { payload["notification"] = notification }
        let mail = try JSONDecoder().decode(MailEvent.self,from:JSONSerialization.data(withJSONObject:payload))
        return .mail(mail)
    }
    @Test func partialDeliveryAckFailureAndRestartNeverRepostSuccessfulMembers() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1,2])]
        let h = NotificationHarness(); defer { h.close() }
        h.center.failureAt = 2
        await h.ready()
        #expect(h.center.posts.count == 2)
        #expect(NotificationHTTP.count("/ack") == 0)
        #expect(h.app.mail.pending.count == 1)
        h.center.failureAt = nil; NotificationHTTP.ackCode = 504
        await h.app.mail.refreshStatus(); await h.app.mailNotifications.waitForWork()
        #expect(h.center.posts.count == 3)
        #expect(NotificationHTTP.count("/ack") == 1)
        h.center.entries = [] // user dismissed successful alerts; persistent receipts still prevent banners
        h.close(removePreferences:false)
        let rebuilt = NotificationHarness(center:h.center, preferences:h.preferences); defer { rebuilt.close() }
        NotificationHTTP.ackCode = 200
        await rebuilt.ready()
        #expect(h.center.posts.count == 3)
        #expect(NotificationHTTP.count("/ack") == 2)
        #expect(NotificationHTTP.count("/synthetic-mail-1") == 0)
        #expect(rebuilt.app.mail.pending.isEmpty)
    }
    @Test func summaryUsesBackendBatchAndRestartRecoversMissedReadsAfterAck() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1,2,3,4],mode:"summary")]
        let h = NotificationHarness(); defer { h.close() }
        await h.ready()
        #expect(h.center.posts.count == 1)
        #expect(NotificationRoute(userInfo:h.center.posts[0].userInfo) == .email(accountID:NotificationHTTP.account,folderID:"INBOX",messageID:nil))
        #expect(NotificationHTTP.count("/ack") == 1)
        h.close(removePreferences:false)
        NotificationHTTP.unseen.remove(2) // no SSE, after ack and app restart
        let rebuilt = NotificationHarness(center:h.center,preferences:h.preferences); defer { rebuilt.close() }
        await rebuilt.ready()
        #expect(h.center.entries.isEmpty)
        #expect(h.center.posts.count == 1)
    }
    @Test(arguments:[NotificationPermission.disabled, .undecided])
    func permissionSuppressionAndUndecidedWait(permission: NotificationPermission) async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        let h = NotificationHarness(); defer { h.close() }
        h.center.permission = permission
        await h.ready()
        #expect(h.center.posts.isEmpty)
        #expect(NotificationHTTP.count("/ack") == (permission == .disabled ? 1 : 0))
        #expect(h.badges.last == 321)
        if permission == .undecided {
            h.center.permission = .allowed
            h.app.notifications.onAuthorizationChange?()
            await h.app.mailNotifications.waitForWork()
            #expect(h.center.posts.count == 1)
            #expect(NotificationHTTP.count("/ack") == 1)
        }
    }
    @Test func onlySameDisplayedBodySuppressesAndSelfMailStillNotifies() async throws {
        NotificationHTTP.reset(); NotificationHTTP.state = "offline"
        let h = NotificationHarness(); defer { h.close() }; await h.ready()
        await h.app.mail.selectMessage("synthetic-mail-1")
        h.app.mail.viewingContext = { ViewingContext(activeModule:.email,isAppActive:true,isWindowVisible:true,selectedChatID:nil,selectedMail:h.app.mail.displayedBodyRoute) }
        h.app.mail.bodyDidDisplay(try #require(h.app.mail.beginBodyPresentation()))
        NotificationHTTP.batches = [NotificationHTTP.batch([1,2])]
        await h.app.mail.refreshStatus(); await h.app.mailNotifications.waitForWork()
        #expect(h.center.posts.count == 1)
        #expect(h.center.posts.first?.body == "合成主题 2")
        #expect(h.center.posts.first?.title == "合成发件人")
        #expect(NotificationHTTP.count("/synthetic-mail-2") == 0) // no body for alerts
        #expect(NotificationHTTP.count("/ack") == 1)
        #expect(NotificationHTTP.count("/read") == 0)
    }
    @Test func bareSelectionNeverSuppressesAndHistoryNeverNotifies() async throws {
        NotificationHTTP.reset(); let h = NotificationHarness(); defer { h.close() }; await h.ready()
        await h.app.mail.selectMessage("synthetic-mail-1")
        h.app.mail.viewingContext = { ViewingContext(activeModule:.email,isAppActive:true,isWindowVisible:true,selectedChatID:nil,selectedMail:h.app.mail.displayedBodyRoute) }
        #expect(h.center.posts.isEmpty)
        NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        await h.app.mail.refreshStatus(); await h.app.mailNotifications.waitForWork()
        #expect(h.center.posts.count == 1)
        #expect(NotificationHTTP.count("/read") == 0)
    }
    @Test func duplicateArrivalsDoNotCreateParallelAddsOrAckBeforeSuccess() async throws {
        NotificationHTTP.reset(); let h = NotificationHarness(); defer { h.close() }; await h.ready()
        let batch = NotificationHTTP.batch([1]); NotificationHTTP.batches = [batch]
        h.center.holdAdd = true
        h.app.receiveStreamEvent(try event("mail.arrived",notification:batch))
        try await wait { h.center.heldAdd != nil }
        for _ in 0..<500 { h.app.receiveStreamEvent(try event("mail.arrived",notification:batch)) }
        #expect(h.app.mailNotifications.workCount == 1)
        #expect(h.center.posts.count == 1)
        #expect(NotificationHTTP.count("/ack") == 0)
        h.center.holdAdd = false; h.center.heldAdd?.resume(); h.center.heldAdd = nil
        await h.app.mailNotifications.waitForWork()
        #expect(h.center.posts.count == 1)
        #expect(NotificationHTTP.count("/ack") == 1)
    }
    @Test func removedAccountCleansLateAddAndKeepsMessages() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        let h = NotificationHarness(); defer { h.close() }
        let chat = LocalNotification(id:"legacy-chat",title:"",body:"",threadID:"",userInfo:["chat_id":"legacy"])
        h.center.entries.append(chat); h.center.holdAdd = true
        let ready = Task { await h.ready() }
        try await wait { h.center.heldAdd != nil }
        await h.app.mail.removeAccount()
        #expect(h.app.unreadCounts.email == 0)
        h.center.holdAdd = false; h.center.heldAdd?.resume(); h.center.heldAdd = nil
        await ready.value; await h.app.mailNotifications.waitForWork()
        #expect(h.center.entries.map(\.id) == ["legacy-chat"])
        #expect(NotificationHTTP.count("/ack") == 0)
        #expect(h.app.mailNotifications.workCount == 0)
    }
    @Test func readDeleteResetAndChatCleanupStayInTheirNamespaces() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1,2,3])]
        let h = NotificationHarness(); defer { h.close() }
        h.center.entries.append(LocalNotification(id:"legacy-chat",title:"",body:"",threadID:"",userInfo:["chat_id":"legacy"]))
        await h.ready(); #expect(h.center.entries.count == 4)
        h.app.mail.applyReadIDs(["synthetic-mail-1"])
        h.app.receiveStreamEvent(try event("mail.updated",deleted:["synthetic-mail-2"]))
        await h.app.mailNotifications.waitForWork()
        #expect(h.center.entries.count == 2)
        NotificationHTTP.validity = 78
        await h.app.mail.refreshStatus(); await h.app.mailNotifications.waitForWork()
        #expect(h.center.entries.map(\.id) == ["legacy-chat"])
        h.app.notifications.clearNotifications(chatID:"legacy")
        try await wait { h.center.entries.isEmpty }
    }
    @Test func reconnectRecoversPendingIndependentOfChatLoginAndOfflineCountsPersist() async throws {
        NotificationHTTP.reset(); let h = NotificationHarness(); defer { h.close() }
        await h.app.refreshAfterEventStreamConnected()
        await h.app.mailNotifications.waitForWork()
        #expect(h.app.status?.state == .loggedOut)
        NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        await h.app.refreshAfterEventStreamConnected(); await h.app.mailNotifications.waitForWork()
        #expect(h.center.posts.count == 1)
        h.app.updateUnread(messages:7)
        for state in ["offline","auth_failed"] {
            NotificationHTTP.state = state; await h.app.mail.refreshStatus()
            #expect(h.app.unreadCounts.total == 328)
            #expect(h.app.unreadCounts.badgeLabel == "99+")
        }
        await h.app.mail.removeAccount()
        #expect(h.app.unreadCounts.total == 7)
        #expect(h.badges.last == 7)
    }
    @Test func wakeBurstsUseOneReconnectNoQRAndNoKeychainReread() async throws {
        NotificationHTTP.reset(); let h = NotificationHarness(); defer { h.close() }; await h.ready()
        let reads = h.credentials.reads
        NotificationHTTP.holdPath = "/mail/sync"
        let workspace = NotificationCenter()
        h.app.observeWake(center:workspace)
        workspace.post(name:NSWorkspace.didWakeNotification,object:nil)
        try await wait { !NotificationHTTP.held.isEmpty }
        for _ in 0..<100 { h.app.systemDidWake() }
        NotificationHTTP.release(); await h.app.waitForWakeWork(); await h.app.mailNotifications.waitForWork()
        #expect(NotificationHTTP.count("/mail/sync") == 1)
        let request = try #require(NotificationHTTP.requests.first { $0.url!.path == "/mail/sync" })
        let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
        #expect(query.contains(URLQueryItem(name:"reconnect",value:"true")))
        #expect(query.contains(URLQueryItem(name:"wait",value:"true")))
        #expect(h.credentials.reads == reads)
        #expect(NotificationHTTP.count("/qr") == 0)
        h.app.shutdown()
        workspace.post(name:NSWorkspace.didWakeNotification,object:nil)
        await Task.yield()
        #expect(NotificationHTTP.count("/mail/sync") == 1)
    }
    @Test func newestClickWaitsForCapabilityAndRoutesOutsidePageThenHandlesMissingAndOldAccount() async throws {
        NotificationHTTP.reset(); let h = NotificationHarness(); defer { h.close() }
        let account = NotificationHTTP.account
        h.app.open(.email(accountID:account,folderID:"INBOX",messageID:"synthetic-mail-1"))
        h.app.open(.email(accountID:account,folderID:"INBOX",messageID:"synthetic-mail-2"))
        #expect(h.windows.isShowingContent)
        #expect(h.app.activeModule == .email)
        #expect(NotificationHTTP.count("/summary") == 0)
        await h.ready(); await h.app.waitForMailRoute()
        #expect(h.app.mail.selectedMessageID == "synthetic-mail-2")
        #expect(h.app.mail.displayedBodyRoute == nil)
        #expect(NotificationHTTP.count("/read") == 0)
        NotificationHTTP.missing.insert(3)
        h.app.open(.email(accountID:account,folderID:"INBOX",messageID:"synthetic-mail-3"))
        await h.app.waitForMailRoute()
        #expect(h.app.mail.selectedMessageID == nil)
        #expect(h.app.mail.routeError != nil)
        h.app.open(.email(accountID:"retired-account",folderID:"INBOX",messageID:"synthetic-mail-1"))
        await h.app.waitForMailRoute()
        #expect(h.app.mail.selectedMessageID == nil)
        #expect(h.app.mail.routeError != nil)
        h.app.open(.email(accountID:account,folderID:"INBOX",messageID:nil))
        await h.app.waitForMailRoute()
        #expect(h.app.mail.selectedMessageID == nil)
    }
    @Test func resetInvalidatesSameValidityTargetsAndLateSystemQueriesCannotRecreateThem() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        let h = NotificationHarness(); defer { h.close() }; await h.ready()
        h.center.holdQuery = true
        await h.app.mail.refreshStatus()
        try await wait { h.center.heldQuery != nil }
        h.app.receiveStreamEvent(try event("mail.updated",reset:true))
        h.center.holdQuery = false; h.center.heldQuery?.resume(); h.center.heldQuery = nil
        await h.app.mailNotifications.waitForWork()
        #expect(h.center.entries.isEmpty)
        #expect(h.center.posts.count == 1)
    }
    @Test func deferredWakeAndSingleMessageClickWaitForInitialMailboxIdentity() async throws {
        NotificationHTTP.reset(); NotificationHTTP.state = "credential_missing"
        let h = NotificationHarness(); defer { h.close() }
        h.app.systemDidWake()
        await h.app.mail.setCapability(features:["mail"])
        await h.app.waitForWakeWork()
        #expect(NotificationHTTP.count("/mail/sync") == 1)
        NotificationHTTP.state = "connecting"
        var initial = NotificationHTTP.snapshot(); initial["uidvalidity"] = NSNull()
        let snapshot = try JSONDecoder().decode(MailStatus.self,from:JSONSerialization.data(withJSONObject:initial))
        let update = try JSONDecoder().decode(MailEvent.self,from:JSONSerialization.data(withJSONObject:[
            "type":"mail.status","account_id":NotificationHTTP.account,"generation":1,"folder_id":"INBOX","status":initial,
            "read_ids":[],"deleted_ids":[],"reset":false]))
        h.app.mail.receive(update)
        #expect(h.app.mail.status == snapshot)
        let route = NotificationRoute.email(accountID:NotificationHTTP.account,folderID:"INBOX",messageID:"synthetic-mail-1")
        h.app.open(route)
        await Task.yield()
        #expect(h.app.pendingMailRoute == route)
        NotificationHTTP.state = "online"
        await h.app.mail.refreshStatus(); await h.app.waitForMailRoute()
        #expect(h.app.mail.selectedMessageID == "synthetic-mail-1")
        #expect(h.app.mail.selectedSummary != nil)
    }
    @Test func staleArrivalAfterAcknowledgedReceiptEvictionMustCheckDurablePending() async throws {
        NotificationHTTP.reset(); let h = NotificationHarness(); defer { h.close() }; await h.ready()
        // Backend has durably acknowledged this batch. Simulate a late duplicate without a local receipt.
        h.app.receiveStreamEvent(try event("mail.arrived",notification:NotificationHTTP.batch([1])))
        await h.app.mailNotifications.waitForWork()
        #expect(h.center.posts.isEmpty)
        #expect(NotificationHTTP.count("/ack") == 0)
        #expect(h.app.mail.pending.isEmpty)
    }
    @Test func persistentReceiptsAreBoundedContainOnlyIDsAndProtectUnacknowledgedWork() async throws {
        NotificationHTTP.reset(); let h = NotificationHarness(); defer { h.close() }
        var records: [String:MailNotificationReceipt] = [:]
        for number in 0..<MailNotificationCoordinator.receiptLimit {
            let id = "old-receipt-\(number)"
            records[id] = MailNotificationReceipt(id:id,accountID:NotificationHTTP.account,uidvalidity:77,batchID:id,
                                                  members:["old-\(number)"],handled:true,acknowledged:true,createdAt:Double(number))
        }
        h.preferences.set(try JSONEncoder().encode(records),forKey:"mail-notification-receipts-v1")
        // Recreate the actual state/coordinator to read the persisted log.
        h.close(removePreferences:false)
        NotificationHTTP.batches = [NotificationHTTP.batch([1])]; NotificationHTTP.ackCode = 504
        let rebuilt = NotificationHarness(center:h.center,preferences:h.preferences); defer { rebuilt.close() }
        await rebuilt.ready()
        let data = try #require(h.preferences.data(forKey:"mail-notification-receipts-v1"))
        let saved = try JSONDecoder().decode([String:MailNotificationReceipt].self,from:data)
        #expect(saved.count <= MailNotificationCoordinator.receiptLimit)
        #expect(saved.values.contains { $0.batchID == "stable-batch" && $0.handled && !$0.acknowledged })
        #expect(!String(decoding:data,as:UTF8.self).contains("合成主题"))
        #expect(!String(decoding:data,as:UTF8.self).contains("synthetic@example.invalid"))
        h.center.entries = []
        NotificationHTTP.ackCode = 200
        await rebuilt.app.mail.refreshStatus(); await rebuilt.app.mailNotifications.waitForWork()
        #expect(h.center.posts.count == 1)
    }
    @Test func interruptedIntentWithoutCenterEntryStaysPendingAcrossRecovery() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        let h = NotificationHarness(); defer { h.close() }
        let route = NotificationRoute.email(accountID:NotificationHTTP.account,folderID:"INBOX",messageID:"synthetic-mail-1")
        let id = route.notificationIdentifier(itemID:"synthetic-mail-1")
        let receipt = MailNotificationReceipt(id:id,accountID:NotificationHTTP.account,uidvalidity:77,batchID:"stable-batch",members:["synthetic-mail-1"],handled:false,acknowledged:false,createdAt:0)
        h.preferences.set(try JSONEncoder().encode([id:receipt]),forKey:"mail-notification-receipts-v1")
        h.close(removePreferences:false)
        let rebuilt = NotificationHarness(center:h.center,preferences:h.preferences); defer { rebuilt.close() }
        await rebuilt.ready()
        #expect(h.center.posts.isEmpty)
        #expect(NotificationHTTP.count("/ack") == 0)
        #expect(rebuilt.app.mail.pending.count == 1)
        NotificationHTTP.ackCode = 504
        await rebuilt.app.mail.refreshStatus(); await rebuilt.app.mailNotifications.waitForWork()
        #expect(h.center.posts.isEmpty)
        let data = try #require(h.preferences.data(forKey:"mail-notification-receipts-v1"))
        let saved = try JSONDecoder().decode([String:MailNotificationReceipt].self,from:data)
        #expect(saved[id]?.handled == false)
        #expect(saved[id]?.acknowledged == false)
        #expect(rebuilt.app.mailNotifications.uncertainDeliveryCount == 1)
        NotificationHTTP.ackCode = 200
        rebuilt.app.mailNotifications.retryUncertainDeliveries()
        await rebuilt.app.mailNotifications.waitForWork()
        #expect(h.center.posts.count == 1)
        #expect(NotificationHTTP.count("/ack") == 1)
        #expect(rebuilt.app.mail.pending.isEmpty)
        #expect(rebuilt.app.mailNotifications.uncertainDeliveryCount == 0)
    }
    @Test func unknownIntentSurvivesAnotherMembersFailureAndExplicitRetryFailureIsRetryable() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1,2])]
        let h = NotificationHarness(); defer { h.close() }
        let route = NotificationRoute.email(accountID:NotificationHTTP.account,folderID:"INBOX",messageID:"synthetic-mail-1")
        let id = route.notificationIdentifier(itemID:"synthetic-mail-1")
        let receipt = MailNotificationReceipt(id:id,accountID:NotificationHTTP.account,uidvalidity:77,batchID:"stable-batch",members:["synthetic-mail-1"],handled:false,acknowledged:false,createdAt:0)
        h.preferences.set(try JSONEncoder().encode([id:receipt]),forKey:"mail-notification-receipts-v1")
        h.close(removePreferences:false)
        let rebuilt = NotificationHarness(center:h.center,preferences:h.preferences); defer { rebuilt.close() }
        h.center.failureAt = 1
        await rebuilt.ready()
        #expect(h.center.posts.count == 1) // only member 2 was attempted and failed
        #expect(rebuilt.app.mailNotifications.uncertainDeliveryCount == 1)
        #expect(NotificationHTTP.count("/ack") == 0)
        h.center.failureAt = 2
        rebuilt.app.mailNotifications.retryUncertainDeliveries()
        await rebuilt.app.mailNotifications.waitForWork()
        #expect(rebuilt.app.mailNotifications.uncertainDeliveryCount == 0) // known failure, no stale intent
        #expect(NotificationHTTP.count("/ack") == 0)
        h.center.failureAt = nil
        await rebuilt.app.mail.refreshStatus(); await rebuilt.app.mailNotifications.waitForWork()
        #expect(h.center.posts.count == 4)
        #expect(NotificationHTTP.count("/ack") == 1)
    }
    @Test func interruptedIntentWithExactCenterEntryIsConfirmedWithoutRepeating() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        let h = NotificationHarness(); defer { h.close() }; NotificationHTTP.ackCode = 504
        await h.ready()
        let data = try #require(h.preferences.data(forKey:"mail-notification-receipts-v1"))
        var records = try JSONDecoder().decode([String:MailNotificationReceipt].self,from:data)
        for id in records.keys { records[id]?.handled = false }
        h.preferences.set(try JSONEncoder().encode(records),forKey:"mail-notification-receipts-v1")
        h.close(removePreferences:false)
        let rebuilt = NotificationHarness(center:h.center,preferences:h.preferences); defer { rebuilt.close() }
        NotificationHTTP.ackCode = 200
        await rebuilt.ready()
        #expect(h.center.posts.count == 1)
        #expect(rebuilt.app.mailNotifications.uncertainDeliveryCount == 0)
        #expect(rebuilt.app.mail.pending.isEmpty)
    }
    @Test func actualOldEpochAddFailureClearsOnlyItsIntentAndCanRetry() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        let h = NotificationHarness(); defer { h.close() }
        h.center.holdAdd = true; h.center.failureAt = 1
        await h.app.mail.setCapability(features:["mail"])
        try await wait { h.center.heldAdd != nil }
        h.app.mailNotifications.backendChanged()
        h.center.holdAdd = false; h.center.heldAdd?.resume(); h.center.heldAdd = nil
        await h.app.mailNotifications.waitForWork()
        let data = try #require(h.preferences.data(forKey:"mail-notification-receipts-v1"))
        #expect(try JSONDecoder().decode([String:MailNotificationReceipt].self,from:data).isEmpty)
        #expect(NotificationHTTP.count("/ack") == 0)
        h.center.failureAt = nil
        h.app.mailNotifications.request(); await h.app.mailNotifications.waitForWork()
        #expect(h.center.posts.count == 2)
        #expect(NotificationHTTP.count("/ack") == 1)
    }
    @Test func notificationCenterAloneRecoversReceiptsAndChecksMovedTargets() async throws {
        NotificationHTTP.reset(); NotificationHTTP.batches = [NotificationHTTP.batch([1])]
        let h = NotificationHarness(); defer { h.close() }; NotificationHTTP.ackCode = 504
        await h.ready()
        h.preferences.removeObject(forKey:"mail-notification-receipts-v1")
        h.close(removePreferences:false)
        let rebuilt = NotificationHarness(center:h.center,preferences:h.preferences); defer { rebuilt.close() }
        NotificationHTTP.ackCode = 200
        await rebuilt.ready()
        #expect(h.center.posts.count == 1)
        NotificationHTTP.missing.insert(1)
        await rebuilt.app.mail.refreshStatus(); await rebuilt.app.mailNotifications.waitForWork()
        #expect(h.center.entries.isEmpty)
    }
    @Test func newestClickWinsWhileOldBodyIsHeldAndAccountRemovalPreventsLateSelection() async throws {
        NotificationHTTP.reset(); let h = NotificationHarness(); defer { h.close() }; await h.ready()
        NotificationHTTP.holdPath = "/mail/messages/synthetic-mail-1"
        h.app.open(.email(accountID:NotificationHTTP.account,folderID:"INBOX",messageID:"synthetic-mail-1"))
        try await wait { !NotificationHTTP.held.isEmpty }
        h.app.open(.email(accountID:NotificationHTTP.account,folderID:"INBOX",messageID:"synthetic-mail-2"))
        NotificationHTTP.release(); await h.app.waitForMailRoute()
        #expect(h.app.mail.selectedMessageID == "synthetic-mail-2")
        #expect(h.app.pendingMailRoute == nil)
        NotificationHTTP.holdPath = "/mail/messages/synthetic-mail-3"
        h.app.open(.email(accountID:NotificationHTTP.account,folderID:"INBOX",messageID:"synthetic-mail-3"))
        try await wait { !NotificationHTTP.held.isEmpty }
        await h.app.mail.removeAccount()
        NotificationHTTP.release(); await h.app.waitForMailRoute()
        #expect(h.app.mail.selectedMessageID == nil)
        #expect(h.app.pendingMailRoute == nil)
    }
}
