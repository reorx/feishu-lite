import Foundation
import Testing
import FeishuLiteCore
@testable import FeishuLiteState

private final class ChatErrorHTTP: URLProtocol {
    static var status = 502
    static var transportError: URLError?
    static var payload = Data(#"{"detail":"synthetic-private-body"}"#.utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Task { @MainActor in
            if let error = Self.transportError {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@Suite(.serialized) @MainActor struct ChatModelErrorTests {
    private func connection() -> BackendConnection {
        ChatErrorHTTP.status = 502
        ChatErrorHTTP.transportError = nil
        ChatErrorHTTP.payload = Data(#"{"detail":"synthetic-private-body"}"#.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatErrorHTTP.self]
        let connection = BackendConnection()
        connection.client = BackendClient(endpoint: BackendEndpoint(
            baseURL: URL(string: "http://synthetic.invalid")!, token: "synthetic"),
            session: URLSession(configuration: config))
        return connection
    }

    private func conversation(_ connection: BackendConnection) -> Conversation {
        Conversation(chat: Chat(id: "synthetic-chat", name: "合成会话", type: .group, unread: 0,
            muted: false, lastMessagePreview: "", lastMessageTime: 0), draft: "原始草稿", connection: connection)
    }

    private func expectSafe(_ message: String?) throws {
        let message = try #require(message)
        #expect(!message.contains("synthetic-private-body"))
        #expect(!message.contains("502"))
        #expect(!message.contains("detail"))
    }

    @Test func sendFailureKeepsDraftAndHidesResponse() async throws {
        let model = conversation(connection())
        await model.send()
        try expectSafe(model.sendError)
        #expect(model.draft == "原始草稿")
        #expect(!model.isSending)
    }

    @Test func latestAndOlderFailuresHideResponseAndKeepHistory() async throws {
        let model = conversation(connection())
        await model.loadLatest(chatLastPosition: 100)
        try expectSafe(model.loadError)
        #expect(!model.hasLoaded)
        ChatErrorHTTP.status = 200
        ChatErrorHTTP.payload = Data(#"[{"id":"synthetic-message","chat_id":"synthetic-chat","position":90,"sender_id":"synthetic-user","sender_name":"合成用户","is_self":false,"create_time":0,"type":"text","text":"合成消息"}]"#.utf8)
        await model.loadLatest(chatLastPosition: 100)
        #expect(model.loadError == nil)
        ChatErrorHTTP.status = 502
        ChatErrorHTTP.payload = Data(#"{"detail":"synthetic-private-body"}"#.utf8)
        await model.loadOlder()
        try expectSafe(model.loadError)
        #expect(model.loadError?.contains("更早") == true)
        #expect(model.rows.count == 1)
        #expect(model.hasOlder)
    }

    @Test func qrFailureHidesResponse() async throws {
        let model = LoginModel(connection: connection())
        defer { model.end() }
        model.begin()
        for _ in 0..<400 {
            if case .failed = model.phase { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case let .failed(message) = model.phase else { Issue.record("二维码请求没有失败"); return }
        try expectSafe(message)
    }

    @Test func loggedOutStillDefersToExistingLogoutFlow() async {
        let model = conversation(connection())
        ChatErrorHTTP.status = 409
        ChatErrorHTTP.payload = Data(#"{"detail":"logged_out"}"#.utf8)
        await model.loadLatest(chatLastPosition: 100)
        await model.send()
        #expect(model.loadError == nil)
        #expect(model.sendError == nil)
        #expect(model.draft == "原始草稿")
    }
}
