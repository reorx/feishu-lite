import Foundation

/// `GET /events` 推过来的事件
public enum BackendEvent: Equatable, Sendable {
    case messageNew(message: Message, chat: Chat)
    case chatUpdated(Chat)
    case status(BackendStatus)

    private struct MessageNewPayload: Decodable {
        var message: Message
        var chat: Chat
    }

    private struct ChatUpdatedPayload: Decodable {
        var chat: Chat
    }

    /// 不认识的事件名返回 nil，方便后端以后加新事件
    public static func decode(_ event: SSEEvent) throws -> BackendEvent? {
        let data = Data(event.data.utf8)
        let decoder = BackendJSON.decoder
        switch event.event {
        case "message.new":
            let payload = try decoder.decode(MessageNewPayload.self, from: data)
            return .messageNew(message: payload.message, chat: payload.chat)
        case "chat.updated":
            return .chatUpdated(try decoder.decode(ChatUpdatedPayload.self, from: data).chat)
        case "status":
            return .status(try decoder.decode(BackendStatus.self, from: data))
        default:
            return nil
        }
    }
}
