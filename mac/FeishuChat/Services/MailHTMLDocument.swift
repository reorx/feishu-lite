import Foundation
import WebKit

/// Supplies exactly one app-owned document from memory; no disk, network or backend access.
@MainActor final class MailHTMLDocument: NSObject, WKURLSchemeHandler {
    let url: URL
    var data: Data?
    private let onRequest: (URL?) -> Void
    init(url: URL, onRequest: @escaping (URL?) -> Void = { _ in }) {
        self.url = url; self.onRequest = onRequest
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        onRequest(task.request.url)
        guard task.request.url == url, let data else {
            task.didFailWithError(URLError(.resourceUnavailable)); return
        }
        task.didReceive(URLResponse(url:url,mimeType:"text/html",expectedContentLength:data.count,textEncodingName:"utf-8"))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
