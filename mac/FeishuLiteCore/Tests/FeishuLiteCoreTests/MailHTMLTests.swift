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
    @Test func envelopeFramesOnlyDataTablesAndMatchesTheNativeReaderTypography() {
        let doc = MailHTMLPolicy.document(content:"<table><tr><td>布局</td></tr></table>", nonce:"synthetic-nonce")
        // 布局表格不画框，只有带表头的数据表格画框
        #expect(!doc.contains("td, th { border"))
        #expect(doc.contains("table:has(> thead > tr > th, > tbody > tr > th, > tfoot > tr > th)"))
        #expect(doc.contains("font-size: \(Int(MailReaderLayout.bodyFontSize))px"))
        #expect(doc.contains("line-height: \(MailReaderLayout.lineHeight)"))
        #expect(doc.contains("max-width: \(Int(MailReaderLayout.maxReadingWidth))px"))
        #expect(doc.contains("padding: \(Int(MailReaderLayout.verticalMargin))px \(Int(MailReaderLayout.horizontalMargin))px"))
        #expect(doc.contains("background: transparent"))
        // 标题不超过邮件主题（17pt）
        for size in MailReaderLayout.headingFontSizes { #expect(size < MailReaderLayout.subjectFontSize) }
        #expect(doc.contains("h1 { font-size: \(Int(MailReaderLayout.headingFontSizes[0]))px"))
    }
}
