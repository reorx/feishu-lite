import Foundation
import AppKit
import Testing
import FeishuChatCore
@testable import FeishuChatState

@MainActor private final class ReaderCredentials: MailCredentialStore {
    func read(accountID: String) throws -> MailSecret { throw MailKeychainError.notFound }
    func write(_ secret: MailSecret, accountID: String, address: String) throws {}
    func delete(accountID: String) throws {}
}
@MainActor private final class ReaderWindows: AppWindows {
    var window: NSWindow? { nil }
    var isShowingContent = false
    func show() { isShowingContent = true }
}

private final class ReaderHTTP: URLProtocol {
    static var requests: [URLRequest] = []
    static var held: [() -> Void] = []
    static var holdPath: String?
    static var first = [105, 104, 103]
    static var next = [103, 102, 101]
    static var bodyCode = 200
    static var readCode = 200
    static var summaryCode = 200
    static var pageCode = 200
    static var account = "reader-account"
    static var state = "online"
    static var unread = 321
    static func reset() {
        requests = []; held = []; holdPath = nil; first = [105,104,103]; next = [103,102,101]
        bodyCode = 200; readCode = 200; summaryCode = 200; pageCode = 200; account = "reader-account"; state = "online"; unread = 321
    }
    static func release() { let work = held; held = []; holdPath = nil; work.forEach { $0() } }
    static func count(_ suffix: String) -> Int { requests.filter { $0.url!.path.hasSuffix(suffix) }.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() { Task { @MainActor in respond() } }
    @MainActor private func respond() {
        Self.requests.append(request)
        let path = request.url!.path
        var code = 200
        var payload: [String: Any]
        if path == "/mail/status" {
            payload = ["mail_account_id":Self.account,"address":"synthetic@example.invalid","state":Self.state,
                       "generation":1,"uidvalidity":77,"last_sync_at":123,"unread_count":Self.unread,
                       "unread_stale":Self.state != "online","pending":[],"error":NSNull()]
        } else if path == "/mail/folders" {
            deliver(code: 200, data: Data(#"[{"id":"INBOX","name":"收件箱","delimiter":"/","flags":[],"selectable":true,"supported":true},{"id":"分类/中文","name":"分类/中文","delimiter":"/","flags":[],"selectable":false,"supported":false}]"#.utf8)); return
        } else if path == "/mail/messages" {
            let paging = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.contains { $0.name == "cursor" } == true
            payload = ["items":(paging ? Self.next : Self.first).map { Self.row($0) },"next_cursor":paging ? NSNull() : "opaque-next"]
            if paging { code = Self.pageCode }
        } else if path.hasSuffix("/summary") {
            code = Self.summaryCode
            payload = Self.row(Int(path.split(separator: "/").dropLast().last!.replacingOccurrences(of: "mail-", with: "")) ?? 9)
        } else if path.hasSuffix("/read") {
            code = Self.readCode
            payload = ["read_ids":[String(path.split(separator:"/").dropLast().last!)]]
        } else {
            code = Self.bodyCode
            payload = ["kind":"plain","content":"合成正文 <script>literal</script>"]
        }
        if code != 200 { payload = ["domain":"mail","code":code == 404 ? "message_missing" : code == 410 ? "stale_cursor" : code == 504 ? "request_timeout" : "offline"] }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        deliver(code: code, data: data)
    }
    @MainActor private func deliver(code: Int, data: Data) {
        let respond = {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url:self.request.url!,statusCode:code,httpVersion:nil,headerFields:nil)!, cacheStoragePolicy:.notAllowed)
            self.client?.urlProtocol(self, didLoad:data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if Self.holdPath == request.url!.path { Self.held.append(respond) } else { respond() }
    }
    static func row(_ uid: Int) -> [String: Any] {
        ["id":"mail-\(uid)","key":["account_id":account,"folder_id":"INBOX","uidvalidity":77,"uid":uid],
         "subject":"合成主题 \(uid)","sender":[],"to":[],"cc":[],"date":"","message_id":"",
         "received_at":200-uid,"size":123,"flags":[],"unread":true,"attachments":[],"body_part":NSNull(),"error":NSNull()]
    }
}

@MainActor func reader() async -> (MailState, UserDefaults, String) {
    ReaderHTTP.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ReaderHTTP.self]
    let connection = BackendConnection()
    connection.client = BackendClient(endpoint:BackendEndpoint(baseURL:URL(string:"http://synthetic.invalid")!,token:"synthetic"),session:URLSession(configuration:config))
    let suite = "d2-reader-" + UUID().uuidString
    let preferences = UserDefaults(suiteName:suite)!
    let mail = MailState(connection:connection, credentials:ReaderCredentials(), externalBackend:true, preferences:preferences)
    mail.backendChanged(ready:true)
    await mail.setCapability(features:["mail"])
    return (mail, preferences, suite)
}
@MainActor func waitReader(_ condition: () -> Bool) async throws {
    for _ in 0..<400 { if condition() { return }; try await Task.sleep(for:.milliseconds(5)) }
    Issue.record("等待阅读器超时")
}
@MainActor func readerRequestCount(_ suffix: String) -> Int { ReaderHTTP.count(suffix) }
@MainActor private func visible(_ mail: MailState, module: AppModule = .email, active: Bool = true, window: Bool = true) -> ViewingContext {
    ViewingContext(activeModule:module,isAppActive:active,isWindowVisible:window,selectedChatID:nil,selectedMail:mail.selectedRoute)
}

@Suite(.serialized) @MainActor struct MailReaderTests {
    @Test func firstAccountStatusStartsReaderAfterEarlierViewHadNoIdentity() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.waitForReaderWork()
        #expect(mail.hasLoadedList)
        #expect(mail.items.map(\.key.uid) == [105,104,103])
    }
    @Test func pageIsOpaqueOrderedDeduplicatedAndBadgeIsWholeInbox() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader()
        #expect(mail.items.map(\.key.uid) == [105,104,103])
        #expect(mail.folders.map(\.id) == ["INBOX","分类/中文"])
        await mail.loadNextPage()
        #expect(mail.items.map(\.key.uid) == [105,104,103,102,101])
        #expect(mail.status?.unreadCount == 321)
        let query = URLComponents(url:ReaderHTTP.requests.last!.url!,resolvingAgainstBaseURL:false)!.queryItems!
        #expect(query.first { $0.name == "cursor" }?.value == "opaque-next")
        #expect(ReaderHTTP.count("/read") == 0)
    }
    @Test func refreshSupersedesHeldPageAndEventsCoalesce() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader()
        ReaderHTTP.holdPath = "/mail/messages"
        let page = Task { await mail.loadNextPage() }
        try await waitReader { !ReaderHTTP.held.isEmpty }
        ReaderHTTP.first = [106,105,104]
        for _ in 0..<300 { mail.requestReaderRefresh() }
        #expect(mail.readerWorkCount == 1)
        ReaderHTTP.release()
        await page.value
        await mail.waitForReaderWork()
        #expect(mail.items.map(\.key.uid) == [106,105,104,103,102,101])
        #expect(ReaderHTTP.count("/mail/messages") <= 4)
        #expect(mail.readerWorkCount == 0)
    }
    @Test func queuedRefreshDuringDirectRefreshAllowsMainActorToProgress() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        ReaderHTTP.holdPath = "/mail/folders"
        let direct = Task { await mail.refreshReader() }
        try await waitReader { !ReaderHTTP.held.isEmpty }
        for _ in 0..<50 { mail.requestReaderRefresh() }
        await Task.yield() // used to spin forever on the main actor before held HTTP could complete
        ReaderHTTP.release()
        await direct.value
        await mail.waitForReaderWork()
        #expect(mail.hasLoadedList)
        #expect(mail.readerWorkCount == 0)
        #expect(ReaderHTTP.count("/mail/folders") <= 2)
    }
    @Test func newHeadDoesNotDropPreviouslyLoadedOldestUID() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        ReaderHTTP.first = Array((201...300).reversed())
        ReaderHTTP.next = Array((151...200).reversed())
        await mail.refreshReader(); await mail.loadNextPage()
        #expect(mail.items.count == 150)
        ReaderHTTP.first = Array((202...301).reversed())
        ReaderHTTP.next = Array((151...201).reversed()) // synthetic final page includes the old boundary
        await mail.refreshReader()
        #expect(mail.items.first?.key.uid == 301)
        #expect(mail.items.last?.key.uid == 151)
        #expect(mail.items.count == 151)
    }
    @Test func readRequiresCurrentSuccessfulRenderAndVisibleEmailAndDeduplicates() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader(); await mail.selectMessage("mail-105")
        mail.viewingContext = { visible(mail) }
        mail.reevaluateViewing()
        #expect(ReaderHTTP.count("/read") == 0)
        let token = try #require(mail.beginBodyPresentation())
        mail.viewingContext = { visible(mail,module:.messages) }
        mail.bodyDidDisplay(token)
        await Task.yield(); #expect(ReaderHTTP.count("/read") == 0)
        for (active,window) in [(false,true),(true,false)] {
            mail.viewingContext = { visible(mail,active:active,window:window) }; mail.reevaluateViewing()
            await Task.yield(); #expect(ReaderHTTP.count("/read") == 0)
        }
        mail.viewingContext = { visible(mail) }
        mail.reevaluateViewing(); mail.reevaluateViewing()
        try await waitReader { ReaderHTTP.count("/read") == 1 && !mail.isReading }
        mail.reevaluateViewing(); await Task.yield()
        #expect(ReaderHTTP.count("/read") == 1)
        mail.bodyDidDisappear(token)
        #expect(mail.displayedBodyRoute == nil)
        #expect(ReaderHTTP.count("/mail/notifications/ack") == 0)
    }
    @Test func lateBodyAndWKCallbackCannotReadNextMailOrAccount() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader(); await mail.selectMessage("mail-105")
        let old = try #require(mail.beginBodyPresentation())
        ReaderHTTP.holdPath = "/mail/messages/mail-104"
        let pending = Task { await mail.selectMessage("mail-104") }
        try await waitReader { !ReaderHTTP.held.isEmpty }
        await mail.selectMessage("mail-103")
        ReaderHTTP.release(); await pending.value
        #expect(mail.selectedMessageID == "mail-103")
        mail.viewingContext = { visible(mail) }
        mail.bodyDidDisplay(old)
        await Task.yield(); #expect(ReaderHTTP.count("/read") == 0)
        let current = try #require(mail.beginBodyPresentation())
        ReaderHTTP.account = "replacement"
        await mail.refreshStatus()
        mail.bodyDidDisplay(current)
        #expect(mail.selectedMessageID == nil)
        #expect(mail.items.isEmpty)
        #expect(ReaderHTTP.count("/read") == 0)
    }
    @Test func sameGenerationOfflineToOnlineStatusAutomaticallyReadsDisplayedTargetOnce() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader(); await mail.selectMessage("mail-105")
        ReaderHTTP.state = "offline"
        await mail.refreshStatus()
        let generation = mail.readerGeneration
        mail.viewingContext = { visible(mail) }
        mail.bodyDidDisplay(try #require(mail.beginBodyPresentation()))
        #expect(ReaderHTTP.count("/read") == 0)
        #expect(mail.readAttempts.isEmpty)
        ReaderHTTP.state = "online"
        await mail.refreshStatus() // production apply(status) must supplement read, without a manual reevaluation
        try await waitReader { ReaderHTTP.count("/read") == 1 && !mail.isReading }
        #expect(mail.readerGeneration == generation)
        for _ in 0..<5 { await mail.refreshStatus() }
        #expect(ReaderHTTP.count("/read") == 1)
    }
    @Test func offlineCachedBodyReadFailureAndExplicitRetry() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader(); await mail.selectMessage("mail-105")
        ReaderHTTP.state = "offline"; await mail.refreshStatus()
        mail.viewingContext = { visible(mail) }
        mail.bodyDidDisplay(try #require(mail.beginBodyPresentation()))
        #expect(ReaderHTTP.count("/read") == 0)
        ReaderHTTP.state = "online"; ReaderHTTP.readCode = 503; await mail.refreshStatus()
        try await waitReader { ReaderHTTP.count("/read") == 1 && !mail.isReading }
        for _ in 0..<10 { mail.reevaluateViewing() }
        #expect(mail.readError != nil)
        #expect(mail.items.first?.unread == true)
        #expect(mail.status?.unreadCount == 321)
        #expect(ReaderHTTP.count("/read") == 1)
        ReaderHTTP.readCode = 200; await mail.retryRead()
        #expect(ReaderHTTP.count("/read") == 2)
    }
    @Test func routeOutsidePageFetchesSummaryAndMissingTargetFallsBack() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader()
        await mail.openRoute(.email(accountID:"reader-account",folderID:"INBOX",messageID:"mail-9"))
        #expect(mail.selectedSummary?.key.uid == 9)
        #expect(ReaderHTTP.count("/mail/messages/mail-9/summary") == 1)
        #expect(mail.items.count == 3)
        ReaderHTTP.summaryCode = 404
        await mail.openRoute(.email(accountID:"reader-account",folderID:"INBOX",messageID:"mail-8"))
        #expect(mail.selectedMessageID == nil)
        #expect(mail.routeError != nil)
        await mail.openRoute(.email(accountID:"other",folderID:"INBOX",messageID:"mail-105"))
        #expect(mail.selectedMessageID == nil)
    }
    @Test func failedBodyOrDisappearedRenderNeverReads() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader()
        ReaderHTTP.bodyCode = 503; await mail.selectMessage("mail-105")
        #expect(mail.beginBodyPresentation() == nil)
        mail.viewingContext = { visible(mail) }; mail.reevaluateViewing()
        #expect(ReaderHTTP.count("/read") == 0)
        ReaderHTTP.bodyCode = 200; await mail.selectMessage("mail-104")
        let token = try #require(mail.beginBodyPresentation())
        mail.bodyDidDisappear(token); mail.bodyDidDisplay(token)
        #expect(mail.displayedBodyRoute == nil)
        #expect(ReaderHTTP.count("/read") == 0)
    }
    @Test func staleCursorRecoversPrefixAndDeletionInvalidatesLateDisplay() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader()
        ReaderHTTP.pageCode = 410
        await mail.loadNextPage()
        #expect(mail.items.map(\.key.uid) == [105,104,103])
        #expect(mail.nextCursor == "opaque-next")
        await mail.selectMessage("mail-105")
        let token = try #require(mail.beginBodyPresentation())
        let raw = #"{"type":"mail.updated","account_id":"reader-account","generation":1,"folder_id":"INBOX","uidvalidity":77,"status":null,"notification":null,"read_ids":[],"deleted_ids":["mail-105"],"reset":false}"#
        mail.receive(try BackendJSON.decoder.decode(MailEvent.self,from:Data(raw.utf8)))
        #expect(mail.selectedMessageID == nil)
        #expect(!mail.items.contains { $0.id == "mail-105" })
        mail.bodyDidDisplay(token)
        #expect(mail.displayedBodyRoute == nil)
    }
    @Test func heldReadFromPreviousSelectionCannotClearNextTargetOrCount() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader(); await mail.selectMessage("mail-105")
        mail.viewingContext = { visible(mail) }
        ReaderHTTP.holdPath = "/mail/messages/mail-105/read"
        mail.bodyDidDisplay(try #require(mail.beginBodyPresentation()))
        try await waitReader { !ReaderHTTP.held.isEmpty }
        await mail.selectMessage("mail-104")
        ReaderHTTP.release()
        await Task.yield()
        #expect(mail.selectedSummary?.id == "mail-104")
        #expect(mail.selectedSummary?.unread == true)
        #expect(mail.status?.unreadCount == 321)
        #expect(ReaderHTTP.count("/read") == 1)
    }
    @Test func updateWithoutStatusAdvancesConnectionIdentityBeforeLateBody() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader()
        ReaderHTTP.holdPath = "/mail/messages/mail-105"
        let body = Task { await mail.selectMessage("mail-105") }
        try await waitReader { !ReaderHTTP.held.isEmpty }
        let raw = #"{"type":"mail.updated","account_id":"reader-account","generation":2,"folder_id":"INBOX","uidvalidity":77,"status":null,"notification":null,"read_ids":[],"deleted_ids":[],"reset":false}"#
        mail.receive(try BackendJSON.decoder.decode(MailEvent.self,from:Data(raw.utf8)))
        ReaderHTTP.release(); await body.value
        if case .loaded = mail.bodyLoadState { Issue.record("旧连接正文不应进入新连接渲染") }
        #expect(mail.beginBodyPresentation() == nil)
    }
    @Test func returningAfterInterruptedReadOffersExplicitRetryWithoutAutomaticWrite() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader(); await mail.selectMessage("mail-105")
        mail.viewingContext = { visible(mail) }
        ReaderHTTP.holdPath = "/mail/messages/mail-105/read"
        let old = try #require(mail.beginBodyPresentation())
        mail.bodyDidDisplay(old)
        try await waitReader { !ReaderHTTP.held.isEmpty }
        mail.bodyDidDisappear(old)
        ReaderHTTP.release()
        await Task.yield()
        mail.bodyDidDisplay(try #require(mail.beginBodyPresentation()))
        await Task.yield()
        #expect(ReaderHTTP.count("/read") == 1)
        #expect(mail.selectedSummary?.unread == true)
        #expect(mail.status?.unreadCount == 321)
        #expect(mail.readError != nil)
        await mail.retryRead()
        #expect(ReaderHTTP.count("/read") == 2)
        #expect(mail.selectedSummary?.unread == false)
    }
    @Test func readTimeoutVerifiesStatusAndExactSummaryWithoutInfiniteRetry() async throws {
        let (mail,prefs,suite) = await reader(); defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.refreshReader(); await mail.selectMessage("mail-105")
        mail.viewingContext = { visible(mail) }; ReaderHTTP.readCode = 504
        mail.bodyDidDisplay(try #require(mail.beginBodyPresentation()))
        try await waitReader { ReaderHTTP.count("/read") == 1 && !mail.isReading }
        #expect(ReaderHTTP.count("/mail/messages/mail-105/summary") == 1)
        #expect(mail.readError != nil)
        for _ in 0..<100 { mail.reevaluateViewing() }
        #expect(ReaderHTTP.count("/read") == 1)
        ReaderHTTP.state = "offline"; await mail.refreshStatus()
        ReaderHTTP.readCode = 200; ReaderHTTP.state = "online"; await mail.refreshStatus()
        await mail.waitForReaderWork()
        await Task.yield()
        #expect(ReaderHTTP.count("/read") == 1) // uncertain STORE is distinct from offline display without a write
        #expect(mail.readError != nil)
        await mail.retryRead()
        #expect(ReaderHTTP.count("/read") == 2)
    }
    @Test func actualAppReevaluateForwardsMailAndRouteIsOnlyVisibleAfterPresentation() async throws {
        _ = NSApplication.shared
        let (_,prefs,suite) = await reader()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReaderHTTP.self]
        let endpoint = BackendEndpoint(baseURL:URL(string:"http://synthetic.invalid")!,token:"synthetic")
        let windows = ReaderWindows()
        let app = AppState(supervisor:BackendSupervisor(config:BackendConfig(uvPath:"",backendDir:"",externalEndpoint:endpoint,homeOverride:nil)),
                           notifications:NotificationService(badgeWriter:{ _ in }, notificationCenter: NotificationCenterRecorder()),windows:windows,preferences:prefs,
                           credentials:ReaderCredentials(),makeClient:{ _ in BackendClient(endpoint:endpoint,session:URLSession(configuration:config)) })
        defer { app.backendStateChanged(.stopped,startEventLoop:false); prefs.removePersistentDomain(forName:suite) }
        app.backendStateChanged(.ready(endpoint),startEventLoop:false)
        await app.mail.setCapability(features:["mail"])
        await app.mail.refreshReader()
        app.activeModule = .email
        await app.mail.selectMessage("mail-105")
        #expect(app.viewingContext.selectedMail == nil)
        app.mail.viewingContext = {
            ViewingContext(activeModule:app.activeModule,isAppActive:true,isWindowVisible:windows.isShowingContent,
                           selectedChatID:nil,selectedMail:app.mail.displayedBodyRoute)
        }
        app.mail.bodyDidDisplay(try #require(app.mail.beginBodyPresentation()))
        app.reevaluateViewing(); await Task.yield()
        #expect(ReaderHTTP.count("/read") == 0)
        windows.isShowingContent = true
        app.activeModule = .messages
        app.reevaluateViewing(); await Task.yield()
        #expect(ReaderHTTP.count("/read") == 0)
        app.activeModule = .email // production didSet calls the shared reevaluation
        try await waitReader { ReaderHTTP.count("/read") == 1 && !app.mail.isReading }
        #expect(app.viewingContext.selectedMail == app.mail.selectedRoute)
        #expect(app.unreadCounts.email == 321)
    }
}
