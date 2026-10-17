import Foundation

/// The app owns this envelope. Backend HTML remains untrusted inside it.
public enum MailHTMLPolicy {
    public static let contentRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#

    public static func externalURL(_ url: URL?, userActivated: Bool) -> URL? {
        guard userActivated, let url, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil else { return nil }
        return url
    }

    public static func document(content: String, nonce: String) -> String {
        // A fresh UUID nonce only authorizes our CSS, never styles inside a mail.
        let csp = "default-src 'none'; script-src 'none'; connect-src 'none'; img-src 'none'; media-src 'none'; font-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; style-src 'nonce-\(nonce)'"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="referrer" content="no-referrer">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style nonce="\(nonce)">\(css)</style></head><body>\(content)</body></html>
        """
    }

    /// 外壳排版：字号、行高、边距和阅读宽度与原生纯文本一致；背景透明，由窗口底色透出。
    /// 布局表格不画框，只有带表头的数据表格画框，以免营销邮件的嵌套表格变成层层方框。
    private static var css: String {
        let layout = MailReaderLayout.self
        let headings = layout.headingFontSizes.map { Int($0) }
        return """
        :root { color-scheme: light dark; } html, body { background: transparent; }
        body { font-family: -apple-system, sans-serif; font-size: \(Int(layout.bodyFontSize))px; line-height: \(layout.lineHeight); overflow-wrap: anywhere; margin: 0; padding: \(Int(layout.verticalMargin))px \(Int(layout.horizontalMargin))px; max-width: \(Int(layout.maxReadingWidth))px; }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.35; margin: 1.1em 0 .45em; } h1 { font-size: \(headings[0])px; } h2 { font-size: \(headings[1])px; } h3, h4, h5, h6 { font-size: \(headings[2])px; }
        body > :first-child { margin-top: 0; } p, ul, ol, pre, blockquote { margin: 0 0 .85em; } ul, ol { padding-left: 1.6em; }
        blockquote { padding-left: 12px; border-left: 3px solid rgba(128, 128, 128, .35); opacity: .8; }
        pre, code { font: 13px/1.45 ui-monospace, Menlo, monospace; } pre { white-space: pre-wrap; } hr { border: 0; border-top: 1px solid rgba(128, 128, 128, .3); margin: 1em 0; }
        a { text-underline-offset: .18em; }
        table { max-width: 100%; border-collapse: collapse; } td, th { padding: 2px 6px 2px 0; vertical-align: top; text-align: start; }
        table:has(> thead > tr > th, > tbody > tr > th, > tfoot > tr > th) { margin: .4em 0 .85em; }
        table:has(> thead > tr > th, > tbody > tr > th, > tfoot > tr > th) > * > tr > :is(td, th) { border: 1px solid rgba(128, 128, 128, .4); padding: 5px 8px; }
        table:has(> thead > tr > th, > tbody > tr > th, > tfoot > tr > th) > * > tr > th { background: rgba(128, 128, 128, .1); font-weight: 600; }
        """
    }
}
