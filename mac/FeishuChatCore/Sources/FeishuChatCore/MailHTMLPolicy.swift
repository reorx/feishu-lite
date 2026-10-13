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
        <style nonce="\(nonce)">
        :root { color-scheme: light dark; } body { font: 15px -apple-system, sans-serif; line-height: 1.65; overflow-wrap: anywhere; margin: 0; padding: 20px; }
        table { max-width: 100%; border-collapse: collapse; } td, th { border: 1px solid GrayText; padding: 6px; } pre { white-space: pre-wrap; } a { text-underline-offset: .18em; }
        </style></head><body>\(content)</body></html>
        """
    }
}
