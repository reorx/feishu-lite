import Foundation
import Testing
@testable import FeishuChatCore

private func wire(_ key: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/mail-wire.json")
    let all = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    return try JSONSerialization.data(withJSONObject: all[key]!)
}

struct MailDecodingTests {
    @Test func realBackendSyntheticWireDecodesWithoutRebuildingIdentifiers() throws {
        let decoder = BackendJSON.decoder
        let empty = try decoder.decode(MailStatus.self, from: wire("GET /mail/status (unconfigured)"))
        #expect(empty.state == .unconfigured)
        #expect(empty.mailAccountID == nil)
        #expect(empty.lastSyncAt == nil)
        let change = try decoder.decode(MailAccountChange.self, from: wire("PUT /mail/account"))
        #expect(change.account != nil)
        let status = try decoder.decode(MailStatus.self, from: wire("POST /mail/sync"))
        #expect(status.lastSyncAt != nil)
        #expect(status.unreadCount > 0)
        let page = try decoder.decode(MailPage.self, from: wire("GET /mail/messages"))
        #expect(!page.items.isEmpty)
        #expect(page.items[0].id != page.items[0].messageID)
        #expect(page.items[0].attachments.isEmpty) // C3b 导出的这页为无附件合成邮件。
        let body = try decoder.decode(MailBody.self, from: wire("GET /mail/messages/{id}"))
        #expect(body.kind == .html || body.kind == .plain)
        _ = try decoder.decode([MailFolder].self, from: wire("GET /mail/folders"))
        _ = try decoder.decode(MailConnectionTest.self, from: wire("POST /mail/account/test"))
        _ = try decoder.decode(MailReadResult.self, from: wire("POST /mail/messages/{id}/read"))
        _ = try decoder.decode(MailAccountChange.self, from: wire("DELETE /mail/account"))
    }

    @Test func mailErrorsNeverExposeResponseOrConfuseChatLogout() {
        let secret = #"{"domain":"mail","code":"evil-secret","password":"synthetic-secret"}"#
        let error = MailAPIError.responseError(status: 403, body: Data(secret.utf8))!
        #expect(!error.localizedDescription.contains("secret"))
        #expect(error.code == "unknown")
        #expect(MailAPIError.responseError(status: 401, body: Data(secret.utf8))?.isLocalTokenFailure == true)
        #expect(BackendError.responseError(status: 409, body: Data(#"{"detail":"logged_out"}"#.utf8)) == .loggedOut)
    }

    @Test func errorPlaceholderAndNullAttachmentSizeDecode() throws {
        let raw = #"{"id":"opaque","key":{"account_id":"test","folder_id":"INBOX","uidvalidity":4294967295,"uid":4294967295},"subject":"","sender":[],"to":[],"cc":[],"date":"","message_id":"","received_at":0,"size":0,"flags":[],"unread":true,"attachments":[{"section":"2","filename":"","media_type":"application/pdf","encoded_size":null,"size_is_approximate":true,"content_id":null}],"body_part":null,"error":"malformed_mime"}"#
        let item = try BackendJSON.decoder.decode(MailSummary.self, from: Data(raw.utf8))
        #expect(item.id == "opaque")
        #expect(item.displaySubject == "（无主题）")
        #expect(item.attachments[0].encodedSize == nil)
        #expect(item.key.uid == 4294967295)
    }
}

struct MailEventDecodingTests {
    @Test func allExportedSSEPayloadsDecodeAndPendingBatchesRemainIntact() throws {
        let pairs = try JSONSerialization.jsonObject(with: wire("SSE")) as! [[Any]]
        for pair in pairs {
            let name = pair[0] as! String
            let data = try JSONSerialization.data(withJSONObject: pair[1])
            let raw = SSEEvent(event: name, data: String(decoding: data, as: UTF8.self))
            let decoded = try #require(try BackendEvent.decode(raw))
            if name.hasPrefix("mail.") {
                guard case let .mail(mail) = decoded else { Issue.record("邮件未独立分派"); continue }
                #expect(mail.type.rawValue == name)
                if let batch = mail.notification {
                    #expect(batch.items.allSatisfy { $0.key.accountID == batch.accountID })
                    #expect(batch.items.allSatisfy { !$0.id.isEmpty })
                }
            }
        }
    }
    @Test func secretsAreRedactedInDescriptionsAndReflectionButEncodedForRequest() throws {
        let secret = MailSecret("synthetic-private")
        #expect(String(describing: secret) == "<redacted>")
        #expect(String(reflecting: secret) == "<redacted>")
        #expect(Mirror(reflecting: secret).children.isEmpty)
        #expect(try BackendJSON.encoder.encode(secret) == Data(#""synthetic-private""#.utf8))
    }
}
