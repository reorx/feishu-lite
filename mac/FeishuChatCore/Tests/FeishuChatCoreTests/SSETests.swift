import Foundation
import Testing
@testable import FeishuChatCore

/// 把一段原始字节按给定的分块方式喂进去，收集解析出的事件
private func parse(_ raw: String, chunkSize: Int = .max) -> [SSEEvent] {
    var decoder = SSEStreamDecoder()
    var events: [SSEEvent] = []
    let bytes = Array(raw.utf8)
    var index = 0
    while index < bytes.count {
        let end = min(bytes.count, index + min(chunkSize, bytes.count))
        events += decoder.feed(bytes[index..<end])
        index = end
    }
    return events
}

@Test func blankLineSeparatesEvents() {
    let raw = "event: status\ndata: {\"state\": \"online\"}\n\nevent: chat.updated\ndata: {\"chat\": 1}\n\n"
    #expect(parse(raw) == [
        SSEEvent(event: "status", data: #"{"state": "online"}"#),
        SSEEvent(event: "chat.updated", data: #"{"chat": 1}"#),
    ])
}

@Test func eventIsNotDispatchedUntilBlankLine() {
    var decoder = SSEStreamDecoder()
    #expect(decoder.feed(Array("event: status\ndata: {}\n".utf8)).isEmpty)
    #expect(decoder.feed(Array("\n".utf8)) == [SSEEvent(event: "status", data: "{}")])
}

@Test func multipleDataLinesAreJoinedWithNewline() {
    let raw = "event: message.new\ndata: {\"a\":\ndata: 1}\n\n"
    #expect(parse(raw) == [SSEEvent(event: "message.new", data: "{\"a\":\n1}")])
}

@Test func commentsAndHeartbeatsAreIgnored() {
    let raw = ": ping\n\n: ping\n\nevent: status\n: 夹在中间的注释\ndata: {}\n\n: ping\n\n"
    #expect(parse(raw) == [SSEEvent(event: "status", data: "{}")])
}

@Test func eventWithoutNameDefaultsToMessage() {
    #expect(parse("data: hello\n\n") == [SSEEvent(event: "message", data: "hello")])
}

@Test func eventNameDoesNotLeakIntoNextEvent() {
    let raw = "event: status\ndata: 1\n\ndata: 2\n\n"
    #expect(parse(raw) == [SSEEvent(event: "status", data: "1"), SSEEvent(event: "message", data: "2")])
}

@Test func eventWithoutDataIsDropped() {
    #expect(parse("event: status\n\nevent: status\ndata: ok\n\n") == [SSEEvent(event: "status", data: "ok")])
}

@Test func onlyOneLeadingSpaceIsStripped() {
    #expect(parse("data:no-space\n\ndata:  two\n\n") == [
        SSEEvent(event: "message", data: "no-space"),
        SSEEvent(event: "message", data: " two"),
    ])
}

@Test func handlesCRLFAndBareCR() {
    #expect(parse("event: status\r\ndata: a\r\n\r\n") == [SSEEvent(event: "status", data: "a")])
    #expect(parse("event: status\rdata: b\r\r") == [SSEEvent(event: "status", data: "b")])
}

@Test func survivesArbitraryChunkBoundaries() {
    // 分块可能落在多字节字符中间，也可能落在 \r 和 \n 之间
    let raw = "event: message.new\r\ndata: {\"text\": \"你好，世界 🌏\"}\r\n\r\n: ping\r\n\r\nevent: status\r\ndata: {}\r\n\r\n"
    let expected = [
        SSEEvent(event: "message.new", data: #"{"text": "你好，世界 🌏"}"#),
        SSEEvent(event: "status", data: "{}"),
    ]
    for size in 1...7 {
        #expect(parse(raw, chunkSize: size) == expected, "chunkSize \(size)")
    }
}

@Test func decodesBackendEvents() throws {
    let chat = #"{"id": "c1", "name": "项目群", "type": "group", "unread": 1, "muted": false, "last_message_preview": "张三: 你好", "last_message_time": 100, "last_position": 5, "rank_time": 100}"#
    let message = #"{"id": "m1", "chat_id": "c1", "position": 5, "sender_id": "u1", "sender_name": "张三", "is_self": false, "create_time": 100, "type": "text", "text": "你好", "badged": true, "at_me": false}"#

    let new = try BackendEvent.decode(SSEEvent(event: "message.new", data: #"{"message": \#(message), "chat": \#(chat)}"#))
    guard case let .messageNew(decodedMessage, decodedChat) = new else {
        Issue.record("expected message.new, got \(String(describing: new))")
        return
    }
    #expect(decodedMessage.id == "m1")
    #expect(decodedChat.unread == 1)

    let updated = try BackendEvent.decode(SSEEvent(event: "chat.updated", data: #"{"chat": \#(chat)}"#))
    guard case let .chatUpdated(updatedChat) = updated else {
        Issue.record("expected chat.updated, got \(String(describing: updated))")
        return
    }
    #expect(updatedChat.lastPosition == 5)

    let status = try BackendEvent.decode(
        SSEEvent(event: "status", data: #"{"state": "reconnecting", "user": {"id": "u", "name": "我"}, "last_error": "ConnectionError: x"}"#))
    #expect(status == .status(BackendStatus(state: .reconnecting, user: User(id: "u", name: "我"), lastError: "ConnectionError: x")))
}

@Test func unknownEventNamesAreSkippedAndBadPayloadsThrow() throws {
    #expect(try BackendEvent.decode(SSEEvent(event: "feed.something_new", data: "{}")) == nil)
    #expect(throws: (any Error).self) {
        try BackendEvent.decode(SSEEvent(event: "status", data: "not json"))
    }
}
