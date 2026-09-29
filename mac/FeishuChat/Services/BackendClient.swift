import FeishuChatCore
import Foundation

enum BackendError: LocalizedError {
    /// 凭证失效（HTTP 409），后端同时会把状态切到 logged_out
    case loggedOut
    case http(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .loggedOut: "登录已失效"
        case let .http(status, detail): "请求失败（\(status)）\(detail)"
        }
    }
}

/// 后端 REST + SSE 接口的客户端，接口定义见 backend/src/feishu_lite/api.py
struct BackendClient {
    static let pageSize = 30
    /// SSE 每 15 秒有一次心跳，空闲超过这个时间就当连接断了
    static let eventIdleTimeout: TimeInterval = 60

    let endpoint: BackendEndpoint
    private let session: URLSession

    init(endpoint: BackendEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        // 本地回环不该走系统代理
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }

    func status() async throws -> BackendStatus {
        try await get("status")
    }

    func startQRLogin() async throws -> String {
        let start: QRLoginStart = try await send("POST", "login/qr")
        return start.qrContent
    }

    func qrLoginStatus() async throws -> QRLoginStatus {
        let poll: QRLoginPoll = try await get("login/qr/status")
        return poll.status
    }

    func logout() async throws {
        _ = try await data(for: request("POST", "logout"))
    }

    func chats() async throws -> [Chat] {
        try await get("chats")
    }

    func messages(chatID: String, before: Int? = nil, limit: Int = pageSize) async throws -> [Message] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            query.append(URLQueryItem(name: "before_position", value: String(before)))
        }
        return try await get("chats/\(chatID)/messages", query: query)
    }

    func send(chatID: String, text: String) async throws -> Message {
        try await send("POST", "chats/\(chatID)/messages", body: BackendJSON.encoder.encode(SendMessageBody(text: text)))
    }

    func markRead(chatID: String) async throws {
        _ = try await data(for: request("POST", "chats/\(chatID)/read"))
    }

    /// 订阅事件流。连接断开或空闲超时时以错误结束，由调用方重连。
    func events() -> AsyncThrowingStream<BackendEvent, Error> {
        var request = request("GET", "events")
        request.timeoutInterval = Self.eventIdleTimeout
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.readEvents(request, session: session, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func readEvents(_ request: URLRequest, session: URLSession,
                                   into continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        try check(response, body: Data())
        var decoder = SSEStreamDecoder()
        for try await byte in bytes {
            guard let raw = decoder.feed(byte), let event = try BackendEvent.decode(raw) else { continue }
            continuation.yield(event)
        }
    }

    // MARK: - 请求

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send("GET", path, query: query)
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                    body: Data? = nil) async throws -> T {
        let data = try await data(for: request(method, path, query: query, body: body))
        return try BackendJSON.decoder.decode(T.self, from: data)
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var url = endpoint.baseURL.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        return data
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 409 {
            throw BackendError.loggedOut
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(status: http.statusCode, detail: String(decoding: body.prefix(200), as: UTF8.self))
        }
    }
}
