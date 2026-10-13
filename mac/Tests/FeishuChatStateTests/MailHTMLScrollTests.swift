import Foundation
import AppKit
import WebKit
import Testing
import FeishuChatCore
@testable import FeishuChatState

// Both the native callback and the timeout run on the main queue; resume exactly once.
@MainActor private func findInWK(_ view: WKWebView, _ text: String) async -> Bool {
    await withCheckedContinuation { continuation in
        var resolved = false
        DispatchQueue.main.asyncAfter(deadline:.now() + 2) {
            guard !resolved else { return }
            resolved = true
            Issue.record("WK find 超过 2 秒期限")
            continuation.resume(returning:false)
        }
        view.find(text,configuration:WKFindConfiguration()) {
            guard !resolved else { return }
            resolved = true
            continuation.resume(returning:$0.matchFound)
        }
    }
}

// Calls the production controller's start/stop and WK delegate lifecycle without a window.
@MainActor private final class ScrollWebView: WKWebView {
    var calls: [String] = []
    var savedState: Any? = Data([1, 2, 3])
    var syntheticNavigation: WKNavigation?
    override var interactionState: Any? {
        get { savedState }
        set { calls.append("restore"); savedState = newValue }
    }
    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        calls.append("load"); syntheticNavigation = super.loadHTMLString("<p>合成</p>",baseURL:nil); return syntheticNavigation
    }
    override func load(_ request: URLRequest) -> WKNavigation? {
        calls.append("load"); syntheticNavigation = super.loadHTMLString("<p>合成</p>",baseURL:nil); return syntheticNavigation
    }
}

@MainActor extension MailReaderTests {
    private func controller(_ mail: MailState, _ view: ScrollWebView, _ content: String = "<p>合成正文</p>") throws -> MailHTMLController {
        let token = try #require(mail.beginBodyPresentation())
        return MailHTMLController(mail:mail,content:content,token:token,webView:view)
    }
    @Test func moduleReconstructionRestoresBeforeAnyFreshDocumentLoad() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let firstView = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let first = try controller(mail,firstView)
        first.start()
        try await waitReader { !firstView.calls.isEmpty }
        first.webView(firstView,didFinish:firstView.syntheticNavigation)
        first.stop()
        #expect(mail.htmlInteractions["mail-105"]?.state != nil)
        let nextView = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let next = try controller(mail,nextView)
        defer { next.stop() }
        next.start()
        try await waitReader { !nextView.calls.isEmpty }
        // interactionState restores a session/navigation; loading first discards its history scroll.
        #expect(nextView.calls == ["restore"])
        #expect(mail.displayedBodyRoute == nil)
    }
    @Test func selectingAnotherMailBeforeDismantleStillSavesTheOldTarget() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let view = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let old = try controller(mail,view)
        old.start()
        try await waitReader { !view.calls.isEmpty }
        old.webView(view,didFinish:view.syntheticNavigation)
        await mail.selectMessage("mail-104")
        let newToken = mail.beginBodyPresentation()
        old.stop()
        #expect(mail.htmlInteractions["mail-105"]?.state != nil)
        #expect(mail.renderToken == newToken)
        #expect(mail.displayedBodyRoute == nil)
        await mail.selectMessage("mail-105")
        let returningView = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let returning = try controller(mail,returningView)
        defer { returning.stop() }
        returning.start(); try await waitReader { !returningView.calls.isEmpty }
        #expect(returningView.calls == ["restore"])
        #expect(mail.displayedToken == nil)
    }
    @Test func realWKSessionReloadsItsMemoryDocumentThroughProductionDelegates() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let content = (1...100).map { "<p>synthetic-paragraph-\($0)</p>" }.joined()
        let token = try #require(mail.beginBodyPresentation())
        let first = MailHTMLController(mail:mail,content:content,token:token)
        first.webView.frame = CGRect(x:0,y:0,width:600,height:400)
        defer { first.stop() }
        first.start()
        try await waitReader { mail.displayedToken == token || mail.renderToken == nil }
        #expect(mail.displayedToken == token)
        let url = try #require(first.webView.url)
        #expect(url.scheme == "feishu-mail-body")
        let found = await findInWK(first.webView,"synthetic-paragraph-80")
        #expect(found)
        first.stop()
        #expect(mail.htmlInteractions["mail-105"]?.state != nil)
        let nextToken = try #require(mail.beginBodyPresentation())
        let next = MailHTMLController(mail:mail,content:content,token:nextToken)
        next.webView.frame = CGRect(x:0,y:0,width:600,height:400)
        defer { next.stop() }
        next.start()
        try await waitReader { mail.displayedToken == nextToken || mail.renderToken == nil }
        #expect(mail.displayedToken == nextToken)
        #expect(next.webView.url == url)
        #expect(next.webView.backForwardList.backList.isEmpty)
        let stillFound = await findInWK(next.webView,"synthetic-paragraph-80")
        #expect(stillFound)
        #expect(next.webView.configuration.userContentController.userScripts.isEmpty)
        #expect(!next.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    @Test func restorationWaitsForProtectionAndRetiredCompilerNeverRestores() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let initialView = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let initial = try controller(mail,initialView)
        initial.start(); try await waitReader { !initialView.calls.isEmpty }
        initial.webView(initialView,didFinish:initialView.syntheticNavigation); initial.stop()
        var release: CheckedContinuation<WKContentRuleList, Error>?
        let view = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let token = try #require(mail.beginBodyPresentation())
        let old = MailHTMLController(mail:mail,content:"<p>合成正文</p>",token:token,webView:view,
            prepareRules:{ try await withCheckedThrowingContinuation { release = $0 } })
        old.start(); try await waitReader { release != nil }
        #expect(view.calls.isEmpty)
        #expect(mail.displayedToken == nil)
        old.stop()
        release!.resume(throwing:URLError(.cancelled))
        try await Task.sleep(for:.milliseconds(20))
        #expect(view.calls.isEmpty)
        #expect(mail.displayedToken == nil)
        #expect(view.navigationDelegate == nil)
    }
    @Test func restorationProtectionFailureIsClosed() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let firstView = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let first = try controller(mail,firstView)
        first.start(); try await waitReader { !firstView.calls.isEmpty }
        first.webView(firstView,didFinish:firstView.syntheticNavigation); first.stop()
        let token = try #require(mail.beginBodyPresentation())
        let view = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let failed = MailHTMLController(mail:mail,content:"<p>合成正文</p>",token:token,webView:view,
            prepareRules:{ throw URLError(.cannotLoadFromNetwork) })
        defer { failed.stop() }
        failed.start(); try await waitReader { mail.renderToken == nil }
        #expect(view.calls.isEmpty)
        #expect(mail.displayedToken == nil)
        if case .failed = mail.bodyLoadState {} else { Issue.record("应显示安全失败") }
    }
    @Test func lateOldSaveAndFinishCannotOverwriteNewPresentation() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let oldView = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let old = try controller(mail,oldView)
        old.start(); try await waitReader { !oldView.calls.isEmpty }
        old.webView(oldView,didFinish:oldView.syntheticNavigation)
        let newView = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let new = try controller(mail,newView)
        defer { new.stop() }
        old.stop()
        old.webView(oldView,didFinish:oldView.syntheticNavigation)
        #expect(mail.renderToken == new.token)
        #expect(mail.displayedToken == nil)
        #expect(mail.htmlInteractions["mail-105"]?.state == nil)
        new.start(); try await waitReader { !newView.calls.isEmpty }
        new.webView(newView,didFinish:newView.syntheticNavigation)
        #expect(mail.displayedToken == new.token)
    }
    @Test func changedBodyNeverRestoresOldSession() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let firstView = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let first = try controller(mail,firstView)
        first.start(); try await waitReader { !firstView.calls.isEmpty }
        first.webView(firstView,didFinish:firstView.syntheticNavigation); first.stop()
        let originalURL = mail.htmlInteractions["mail-105"]?.documentURL
        let view = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let changed = try controller(mail,view,"<p>新正文</p>")
        defer { changed.stop() }
        changed.start(); try await waitReader { !view.calls.isEmpty }
        #expect(view.calls == ["load"])
        #expect(mail.htmlInteractions["mail-105"]?.documentURL != originalURL)
    }
    @Test func accountValidityConnectionAndEpochChangesRejectOldLocations() {
        let cache = MailHTMLInteractionCache()
        let original = MailReaderIdentity(epoch:1,accountID:"synthetic-a",generation:1,uidvalidity:77,messageID:"synthetic-id")
        let token = MailRenderToken(identity:original,selection:1,presentation:UUID())
        cache.claim(token:token,content:"synthetic")
        cache.save(Data([1]),token:token)
        let variants = [
            MailReaderIdentity(epoch:2,accountID:"synthetic-a",generation:1,uidvalidity:77,messageID:"synthetic-id"),
            MailReaderIdentity(epoch:1,accountID:"synthetic-b",generation:1,uidvalidity:77,messageID:"synthetic-id"),
            MailReaderIdentity(epoch:1,accountID:"synthetic-a",generation:2,uidvalidity:77,messageID:"synthetic-id"),
            MailReaderIdentity(epoch:1,accountID:"synthetic-a",generation:1,uidvalidity:78,messageID:"synthetic-id")]
        for identity in variants {
            let next = MailRenderToken(identity:identity,selection:1,presentation:UUID())
            #expect(cache.claim(token:next,content:"synthetic").state == nil)
            cache.save(Data([1]),token:next)
        }
        cache.removeAll()
        #expect(cache.count == 0)
    }
    @Test func interactionMemoryIsBoundedAndOversizedStateIsDiscarded() {
        let cache = MailHTMLInteractionCache()
        for index in 0..<20 {
            let identity = MailReaderIdentity(epoch:1,accountID:"synthetic",generation:1,uidvalidity:77,messageID:"mail-\(index)")
            let token = MailRenderToken(identity:identity,selection:index,presentation:UUID())
            cache.claim(token:token,content:"synthetic")
            cache.save(Data(repeating:0,count:256 * 1024 + 1),token:token)
            #expect(cache["mail-\(index)"]?.state == nil)
        }
        #expect(cache.count == 8)
        #expect(cache["mail-0"] == nil)
    }
    @Test func documentNavigationOnlyAllowsTheExactTopLevelInitialTarget() throws {
        let url = URL(string:"feishu-mail-body://document/synthetic")!
        var external: [URL] = []
        let router = MailNavigationRouter(documentURL:url,openExternal:{ external.append($0) })
        #expect(!router.decide(url:url,userActivated:false,mainFrame:false,newWindow:false))
        #expect(!router.decide(url:URL(string:"feishu-mail-body://document/other"),userActivated:false,mainFrame:true,newWindow:false))
        #expect(router.decide(url:url,userActivated:false,mainFrame:true,newWindow:false))
        #expect(!router.decide(url:url,userActivated:false,mainFrame:true,newWindow:false))
        #expect(!router.decide(url:url,userActivated:true,mainFrame:true,newWindow:false))
        #expect(!router.decide(url:URL(string:"file:///tmp/synthetic"),userActivated:true,mainFrame:true,newWindow:false))
        #expect(!router.decide(url:URL(string:"https://synthetic.invalid"),userActivated:false,mainFrame:true,newWindow:false))
        #expect(external.isEmpty)
        let rules = try JSONSerialization.jsonObject(with:Data(MailHTMLController.contentRules(documentURL:url).utf8)) as! [[String:Any]]
        #expect(rules.count == 2)
        let exception = rules[1]["trigger"] as! [String:Any]
        #expect(exception["resource-type"] as? [String] == ["document"])
        let pattern = try #require(exception["url-filter"] as? String)
        let regex = try NSRegularExpression(pattern:pattern)
        for candidate in ["http://127.0.0.1/", "file:///tmp/synthetic", url.absoluteString + "/resource", url.absoluteString + "?resource=1", url.absoluteString + "#frame", "feishu-mail-body://document/other"] {
            #expect(regex.firstMatch(in:candidate,range:NSRange(candidate.startIndex...,in:candidate)) == nil)
        }
    }

    @Test func realWKBlocksSameSchemeResourcesFramesAndScriptOnFirstLoadAndRestore() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let content = """
        <h1>synthetic-safe-text</h1>
        <script>document.body.textContent='SYNTHETIC_SCRIPT_EXECUTED'</script>
        <img src="feishu-mail-body://document/other-image">
        <link rel="stylesheet" href="feishu-mail-body://document/other-style">
        <iframe src="feishu-mail-body://document/other-frame"></iframe>
        <object data="feishu-mail-body://document/other-object"></object>
        <a href="feishu-mail-body://document/other-user">synthetic-scheme-link</a>
        """
        var requests: [URL?] = []
        let firstToken = try #require(mail.beginBodyPresentation())
        let first = MailHTMLController(mail:mail,content:content,token:firstToken,onDocumentRequest:{ requests.append($0) })
        defer { first.stop() }
        first.webView.frame = CGRect(x:0,y:0,width:600,height:400)
        first.start(); try await waitReader { mail.displayedToken == firstToken || mail.renderToken == nil }
        #expect(mail.displayedToken == firstToken)
        try await Task.sleep(for:.milliseconds(50))
        let url = try #require(first.webView.url)
        #expect(requests == [url])
        let marker = await findInWK(first.webView,"SYNTHETIC_SCRIPT_EXECUTED")
        #expect(!marker)
        first.stop()
        let token = try #require(mail.beginBodyPresentation())
        let next = MailHTMLController(mail:mail,content:content,token:token,onDocumentRequest:{ requests.append($0) })
        defer { next.stop() }
        next.webView.frame = CGRect(x:0,y:0,width:600,height:400)
        next.start(); try await waitReader { mail.displayedToken == token || mail.renderToken == nil }
        #expect(mail.displayedToken == token)
        try await Task.sleep(for:.milliseconds(50))
        #expect(requests == [url,url])
    }
    @Test func normalAndBlankHTTPLinksStillOpenWithoutAllowingSchemeClicks() {
        let document = URL(string:"feishu-mail-body://document/synthetic")!
        var external: [URL] = []
        let router = MailNavigationRouter(documentURL:document,openExternal:{ external.append($0) })
        #expect(router.decide(url:document,userActivated:false,mainFrame:true,newWindow:false))
        for target in [document, URL(string:"feishu-mail-body://document/other")!] {
            #expect(!router.decide(url:target,userActivated:true,mainFrame:true,newWindow:false))
            #expect(!router.decide(url:target,userActivated:true,mainFrame:false,newWindow:true))
            router.popup(url:target,userActivated:true)
        }
        let normal = URL(string:"https://synthetic.invalid/normal")!
        let blank = URL(string:"http://127.0.0.1/blank")!
        #expect(!router.decide(url:normal,userActivated:true,mainFrame:true,newWindow:false))
        #expect(router.decide(url:blank,userActivated:true,mainFrame:false,newWindow:true))
        router.popup(url:blank,userActivated:true)
        #expect(external == [normal,blank])
    }

    @Test func restorationDoesNotAcceptOldNavigationAsCurrentDisplayEvidence() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let oldView = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let old = try controller(mail,oldView)
        old.start(); try await waitReader { !oldView.calls.isEmpty }
        old.webView(oldView,didFinish:oldView.syntheticNavigation); old.stop()
        let view = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let next = try controller(mail,view)
        defer { next.stop() }
        next.start(); try await waitReader { !view.calls.isEmpty }
        next.webView(view,didFinish:oldView.syntheticNavigation)
        #expect(mail.displayedToken == nil)
        // Obtain a genuine WKNavigation handle, never instantiate WKNavigation directly.
        let source = WKWebView(frame:.zero,configuration:MailHTMLController.configuration())
        defer { source.stopLoading() }
        let restored = try #require(source.loadHTMLString("<p>合成</p>",baseURL:nil))
        next.webView(view,didStartProvisionalNavigation:restored)
        next.webView(view,didFinish:oldView.syntheticNavigation)
        #expect(mail.displayedToken == nil)
        next.webView(view,didFinish:restored)
        #expect(mail.displayedToken == next.token)
    }

    @Test func staleControllerConstructionCannotClaimTheNewCacheOwner() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let view = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let first = try controller(mail,view)
        let nextView = ScrollWebView(frame:.zero,configuration:MailHTMLController.configuration())
        let next = try controller(mail,nextView)
        defer { first.stop(); next.stop() }
        let stale = MailHTMLController(mail:mail,content:"<p>旧正文</p>",token:first.token,webView:view)
        defer { stale.stop() }
        #expect(mail.htmlInteractions["mail-105"]?.owner == next.token.presentation)
    }

}
