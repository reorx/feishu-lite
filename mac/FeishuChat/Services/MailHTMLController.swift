import AppKit
import FeishuChatCore
import WebKit

/// The same router is called by both WK delegates. No popup web view is created.
@MainActor final class MailNavigationRouter {
    private var awaitingInitialDocument = true
    private let documentURL: URL?
    let openExternal: (URL) -> Void
    init(documentURL: URL? = nil, openExternal: @escaping (URL) -> Void) { self.documentURL = documentURL; self.openExternal = openExternal }
    func decide(url: URL?, userActivated: Bool, mainFrame: Bool, newWindow: Bool) -> Bool {
        if awaitingInitialDocument, mainFrame, !newWindow, !userActivated,
           (documentURL == nil ? (url == nil || url?.absoluteString == "about:blank") : url == documentURL) {
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
    private let document: MailHTMLDocument
    private let restoration: Data?
    private var awaitingRestoredNavigation = false
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
         webView: WKWebView? = nil,
         prepareRules: (() async throws -> WKContentRuleList)? = nil,
         onDocumentRequest: @escaping (URL?) -> Void = { _ in },
         openExternal: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.mail = mail; self.content = content; self.token = token
        let entry = mail.renderToken == token
            ? mail.htmlInteractions.claim(token:token,content:content)
            : MailHTMLInteraction(token:token,content:content)
        document = MailHTMLDocument(url:entry.documentURL,onRequest:onDocumentRequest)
        restoration = entry.state
        router = MailNavigationRouter(documentURL:entry.documentURL,openExternal:openExternal)
        let config = Self.configuration()
        config.setURLSchemeHandler(document,forURLScheme:"feishu-mail-body")
        self.webView = webView ?? WKWebView(frame:.zero,configuration:config)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        gate = MailHTMLLoadGate(prepare: { [weak self] in
            guard let self else { throw CancellationError() }
            let rules = try await (prepareRules ?? { try await Self.compileRules(documentURL:self.document.url) })()
            guard !self.stopped, !Task.isCancelled else { throw CancellationError() }
            self.webView.configuration.userContentController.add(rules)
        }, load: { [weak self] html in
            guard let self, !self.stopped else { return }
            guard self.mail?.renderToken == self.token else { return }
            self.document.data = Data(html.utf8)
            if let restoration = self.restoration {
                // The setter restores history AND initiates a navigation. Do not load a fresh
                // document first, or restore again in didFinish (which starts a second load).
                self.awaitingRestoredNavigation = true
                self.webView.interactionState = restoration
            } else {
                self.navigation = self.webView.load(URLRequest(url:self.document.url))
                if self.navigation == nil { self.mail?.bodyRenderFailed(self.token) }
            }
        })
    }
    static func contentRules(documentURL: URL) throws -> String {
        // Only the exact in-memory top document may load. Subresources remain blocked;
        // frame CSP and the delegate independently prohibit using it as a nested frame.
        let rules: [[String: Any]] = [
            ["trigger":["url-filter":".*"],"action":["type":"block"]],
            ["trigger":["url-filter":"^" + NSRegularExpression.escapedPattern(for:documentURL.absoluteString) + "$",
                        "resource-type":["document"]],"action":["type":"ignore-previous-rules"]]
        ]
        return String(decoding:try JSONSerialization.data(withJSONObject:rules),as:UTF8.self)
    }
    private static func compileRules(documentURL: URL) async throws -> WKContentRuleList {
        let encoded = try contentRules(documentURL:documentURL)
        return try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"feishu-mail-no-resources-v1",encodedContentRuleList:encoded) { rules, error in
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
        // Selection may already point at another mail when SwiftUI dismantles this view.
        // The cache owner prevents an older view from overwriting a newer presentation.
        if successfullyDisplayed, var scope = mail?.readerIdentity {
            scope.messageID = token.identity.messageID
            if scope == token.identity { mail?.htmlInteractions.save(webView.interactionState,token:token) }
        }
        mail?.bodyDidDisappear(token)
        gate.stop(); loading?.cancel(); loading = nil
        webView.stopLoading()
        document.data = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // Keep the blocker attached through teardown, including pending resource retries.
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !stopped, awaitingRestoredNavigation else { return }
        self.navigation = navigation
        awaitingRestoredNavigation = false
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped, let navigation, navigation === self.navigation else { return }
        guard mail?.renderToken == token else { return }
        successfullyDisplayed = true
        mail?.bodyDidDisplay(token)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(navigation) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(navigation) }
    private func fail(_ navigation: WKNavigation?) {
        guard !stopped, let navigation, navigation === self.navigation else { return }
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
