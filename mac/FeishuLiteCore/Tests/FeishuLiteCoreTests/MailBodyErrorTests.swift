import Foundation
import Testing
@testable import FeishuLiteCore

struct MailBodyErrorTests {
    @Test func malformedBodyExplainsWhyRetryCannotHelp() {
        let error = MailAPIError(status: 422, code: "malformed_mime")
        #expect(error.localizedDescription == "这封邮件的格式已损坏，无法解析正文。请使用飞书邮箱查看。")
        #expect(!error.localizedDescription.contains("重试"))
    }

    @Test func contentAndLimitFailuresCannotBeRetried() {
        let codes = ["malformed_mime", "malformed_encoding", "unsupported_charset", "mime_too_deep",
            "too_many_parts", "unsupported_transfer_encoding", "unsupported_body", "body_too_large",
            "headers_too_large", "response_too_large"]
        var descriptions: Set<String> = []
        for code in codes {
            let error = MailAPIError(status: 422, code: code)
            #expect(!error.isBodyRetryable)
            #expect(!error.localizedDescription.contains("重试"))
            #expect(error.localizedDescription.contains("飞书邮箱"))
            descriptions.insert(error.localizedDescription)
        }
        #expect(descriptions.count == codes.count)
    }

    @Test func transportAndUnknownFailuresRemainRetryable() {
        for code in ["offline", "request_timeout", "queue_full", "transport_failed", "malformed_response", "new-code"] {
            #expect(MailAPIError(status: 503, code: code).isBodyRetryable)
        }
    }
}
