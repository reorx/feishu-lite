import FeishuChatCore
import Foundation

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

    /// 隔离行为测试注入 URLProtocol；生产仍使用上面的回环配置。
    init(endpoint: BackendEndpoint, session: URLSession) {
        self.endpoint = endpoint
        self.session = session
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

    func image(messageID: String) async throws -> Data {
        try await data(for: request("GET", "messages/\(messageID)/image"))
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

    /// 邮件 HTTP 边界只交付安全错误；不沿用聊天的响应前缀/登出映射。
    func mailRequest<T: Decodable>(_ method: String, _ components: [String], query: [URLQueryItem] = [],
                                   body: Data? = nil) async throws -> T {
        var url = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let path = components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        url.percentEncodedPath = url.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path
        if !url.percentEncodedPath.hasPrefix("/") { url.percentEncodedPath = "/" + url.percentEncodedPath }
        url.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        request.timeoutInterval = Self.mailRequestTimeout
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               let error = MailAPIError.responseError(status: http.statusCode, body: data) { throw error }
            return try BackendJSON.decoder.decode(T.self, from: data)
        } catch let error as MailAPIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw MailAPIError(status: 504, code: "request_timeout")
        } catch is DecodingError {
            throw MailAPIError(status: 502, code: "malformed_response")
        } catch {
            throw MailAPIError(status: 503, code: "transport_failed")
        }
    }

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
        if let error = BackendError.responseError(status: http.statusCode, body: body) {
            throw error
        }
    }
}
