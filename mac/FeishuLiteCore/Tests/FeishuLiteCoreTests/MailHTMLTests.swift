import Foundation
import Testing
@testable import FeishuLiteCore

struct MailHTMLTests {
    @Test func onlyUserHTTPLinksCanOpenIncludingIntranetAndBlank() {
        for text in ["https://example.invalid/a", "http://intranet/path", "http://127.0.0.1:9876/path", "https://[::1]/"] {
            let url = URL(string:text)!
            #expect(MailHTMLPolicy.externalURL(url, userActivated:true) == url)
            #expect(MailHTMLPolicy.externalURL(url, userActivated:false) == nil)
        }
        for text in ["file:///etc/hosts","data:text/html,test","javascript:alert(1)","feishu://foo","about:blank","https:///", "mailto:test@example.invalid"] {
            #expect(MailHTMLPolicy.externalURL(URL(string:text),userActivated:true) == nil)
        }
    }
    @Test func documentHasStrictCSPNoBaseAndBlocksEveryResource() throws {
        let doc = MailHTMLPolicy.document(content:"<p>合成正文</p>", nonce:"synthetic-nonce")
        #expect(doc.contains("default-src 'none'"))
        #expect(doc.contains("script-src 'none'"))
        #expect(doc.contains("connect-src 'none'"))
        #expect(doc.contains("form-action 'none'"))
        #expect(doc.contains("base-uri 'none'"))
        #expect(doc.contains("style-src 'nonce-synthetic-nonce'"))
        #expect(!doc.contains("unsafe-inline"))
        let rules = try JSONSerialization.jsonObject(with:Data(MailHTMLPolicy.contentRules.utf8)) as! [[String:Any]]
        #expect(rules.count == 1)
        #expect((rules[0]["trigger"] as! [String:Any])["url-filter"] as? String == ".*")
        #expect((rules[0]["action"] as! [String:Any])["type"] as? String == "block")
    }
}
