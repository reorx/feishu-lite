import AppKit
import FeishuChatCore
import WebKit

struct MailHTMLInteraction {
    let identity: MailReaderIdentity
    let content: String
    let state: Any
}

/// The same router is called by both WK delegates. No popup web view is created.
@MainActor final class MailNavigationRouter {
    private var awaitingInitialDocument = true
    let openExternal: (URL) -> Void
    init(openExternal: @escaping (URL) -> Void) { self.openExternal = openExternal }
    func decide(url: URL?, userActivated: Bool, mainFrame: Bool, newWindow: Bool) -> Bool {
        if awaitingInitialDocument, mainFrame, !newWindow, !userActivated,
           url == nil || url?.absoluteString == "about:blank" {
            awaitingInitialDocument = false
            return true
        }
        if let target = MailHTMLPolicy.externalURL(url,userActivated:userActivated) {
            if newWindow { return true } // WKUIDelegate receives the click and returns no new view.
            openExternal(target)
        }
        return false
    }
    func popup(url: URL?, userActivated: Bool) {
        if let target = MailHTMLPolicy.externalURL(url,userActivated:userActivated) { openExternal(target) }
    }
}

/// Owns only this mail's ephemeral view. Configuration has no backend credentials.
@MainActor final class MailHTMLController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let token: MailRenderToken
    private weak var mail: MailState?
    private var navigation: WKNavigation?
    private var loading: Task<Void, Never>?
    private var stopped = false
    private var successfullyDisplayed = false
    private let content: String
    private let router: MailNavigationRouter
    private var gate: MailHTMLLoadGate!

    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController = WKUserContentController()
        config.suppressesIncrementalRendering = true
        return config
    }

    init(mail: MailState, content: String, token: MailRenderToken,
         openExternal: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.mail = mail; self.content = content; self.token = token
        router = MailNavigationRouter(openExternal:openExternal)
        webView = WKWebView(frame:.zero,configuration:Self.configuration())
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        gate = MailHTMLLoadGate(prepare: { [weak self] in
            guard let self else { throw CancellationError() }
            let rules = try await Self.compileRules()
            guard !self.stopped, !Task.isCancelled else { throw CancellationError() }
            self.webView.configuration.userContentController.add(rules)
        }, load: { [weak self] html in
            guard let self, !self.stopped else { return }
            self.navigation = self.webView.loadHTMLString(html,baseURL:nil)
            if self.navigation == nil { self.mail?.bodyRenderFailed(self.token) }
        })
    }
    private static func compileRules() async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"feishu-mail-no-resources-v1",encodedContentRuleList:MailHTMLPolicy.contentRules) { rules, error in
                if let rules, error == nil { continuation.resume(returning:rules) }
                else { continuation.resume(throwing:MailHTMLRuleError.unavailable) }
            }
        }
    }
    func start() {
        guard loading == nil else { return }
        loading = Task { [weak self] in
            guard let self else { return }
            await self.gate.start(document:MailHTMLPolicy.document(content:self.content,nonce:UUID().uuidString))
            if self.gate.state == .failed, !self.stopped { self.mail?.bodyRenderFailed(self.token) }
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        // Public WK state includes scroll position; kept only in memory for this identity/body.
        if successfullyDisplayed, mail?.selectedMessageID == token.identity.messageID,
           mail?.readerIdentity?.epoch == token.identity.epoch,
           mail?.readerIdentity?.accountID == token.identity.accountID,
           mail?.readerIdentity?.uidvalidity == token.identity.uidvalidity,
           let id = token.identity.messageID, let state = webView.interactionState {
            mail?.htmlInteractions[id] = MailHTMLInteraction(identity:token.identity,content:content,state:state)
        }
        mail?.bodyDidDisappear(token)
        gate.stop(); loading?.cancel(); loading = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // Keep the blocker attached through teardown, including pending resource retries.
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped, navigation === self.navigation else { return }
        if let id = token.identity.messageID, let stored = mail?.htmlInteractions[id],
           stored.identity == token.identity, stored.content == content {
            webView.interactionState = stored.state
        }
        successfullyDisplayed = true
        mail?.bodyDidDisplay(token)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(navigation) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(navigation) }
    private func fail(_ navigation: WKNavigation?) {
        guard !stopped, navigation === self.navigation else { return }
        mail?.bodyRenderFailed(token)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if !stopped { mail?.bodyRenderFailed(token) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !stopped else { decisionHandler(.cancel); return }
        let allow = router.decide(url:action.request.url,userActivated:action.navigationType == .linkActivated,
                                  mainFrame:action.targetFrame?.isMainFrame == true,newWindow:action.targetFrame == nil)
        decisionHandler(allow ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if !stopped { router.popup(url:action.request.url,userActivated:action.navigationType == .linkActivated) }
        return nil
    }
}
private enum MailHTMLRuleError: Error { case unavailable }
