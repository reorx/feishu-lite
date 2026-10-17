import Foundation
import Testing
@testable import FeishuLiteCore

struct ChatErrorTests {
    @Test func rawHTTPDetailsNeverBecomeUserDescriptions() throws {
        for status in [400, 401, 403, 404, 409, 429, 500, 502, 504] {
            let error = try #require(BackendError.responseError(
                status: status, body: Data(#"{"detail":"synthetic-private-body"}"#.utf8)))
            #expect(!error.localizedDescription.contains("synthetic-private-body"))
            #expect(!error.localizedDescription.contains(String(status)))
        }
    }

    @Test func actionAndStatusExplainTheFailureWithoutRawDetails() {
        let error = BackendError.http(status: 502, detail: "synthetic-private-body")
        let expected: [(BackendError.Action, String)] = [
            (.send, "发送失败"), (.loadMessages, "加载消息失败"), (.loadOlderMessages, "加载更早的消息失败"),
            (.getQRCode, "获取二维码失败"), (.loadImage, "图片加载失败")
        ]
        for (action, prefix) in expected {
            #expect(error.userMessage(for: action) == "\(prefix)：飞书服务暂时不可用，请稍后重试。")
        }
        for action in BackendError.Action.allCases {
            #expect(BackendError.http(status: 401, detail: "secret").userMessage(for: action).contains("本机"))
            #expect(BackendError.http(status: 403, detail: "secret").userMessage(for: action).contains("权限"))
            #expect(BackendError.http(status: 429, detail: "secret").userMessage(for: action).contains("频繁"))
            #expect(BackendError.http(status: 504, detail: "secret").userMessage(for: action).contains("超时"))
        }
        #expect(BackendError.http(status: 404, detail: "secret").userMessage(for: .loadMessages).contains("会话"))
        #expect(BackendError.http(status: 404, detail: "secret").userMessage(for: .loadImage) == "图片已撤回或不可用")
    }

    @Test func unknownAndTransportErrorsHaveSafeContext() {
        let unknown = NSError(domain: "synthetic-private-body", code: 123, userInfo: [NSLocalizedDescriptionKey: "secret"])
        for action in BackendError.Action.allCases {
            let text = BackendError.userMessage(for: unknown, action: action)
            #expect(!text.contains("secret"))
            #expect(!text.contains("synthetic"))
        }
        #expect(BackendError.userMessage(for: URLError(.timedOut), action: .send).contains("超时"))
        #expect(BackendError.userMessage(for: URLError(.notConnectedToInternet), action: .loadMessages).contains("连接"))
    }

    @Test func diagnosticsAndLoggedOutMappingStayAvailable() {
        let data = Data(#"{"detail":"synthetic-private-body"}"#.utf8)
        let error = BackendError.responseError(status: 502, body: data)
        #expect(error == .http(status: 502, detail: String(decoding: data, as: UTF8.self)))
        #expect(BackendError.responseError(status: 200, body: data) == nil)
        #expect(BackendError.responseError(status: 409, body: Data(#"{"detail":"logged_out"}"#.utf8)) == .loggedOut)
        #expect(BackendError.responseError(status: 401, body: Data(#"{"detail":"logged_out"}"#.utf8)) != .loggedOut)
        #expect(BackendError.loggedOut.userMessage(for: .send) == "登录已失效")
    }

    @Test func imageUnavailableAndDecodeFailuresArePermanent() {
        let missing = ImageMessageFailure(error: BackendError.http(status: 404, detail: "secret"))
        #expect(!missing.canRetry)
        #expect(missing.message == "图片已撤回或不可用")
        #expect(!ImageMessageFailure.decodingFailed.canRetry)
        #expect(ImageMessageFailure.decodingFailed.message == "无法显示这张图片")
    }

    @Test func otherImageFailuresRemainRetryableAndSafe() {
        let errors: [any Error] = [BackendError.http(status: 500, detail: "secret"),
            BackendError.http(status: 403, detail: "secret"), BackendError.loggedOut,
            URLError(.timedOut), NSError(domain: "secret", code: 9)]
        for error in errors {
            let failure = ImageMessageFailure(error: error)
            #expect(failure.canRetry)
            #expect(!failure.message.contains("secret"))
        }
    }
}
