import Foundation
import Testing
@testable import FeishuChatCore

// 样本按 backend/src/feishu_lite/types.py 的输出形状手写，人名、内容和 id 都是假的。

private func data(_ json: String) -> Data { Data(json.utf8) }

@Test func decodesChatList() throws {
    let json = """
    [
      {"id": "7000000000000000001", "name": "项目群", "type": "group", "unread": 3, "muted": true,
       "last_message_preview": "张三: 明天开会", "last_message_time": 1790000000,
       "last_position": 41, "rank_time": 1790000005},
      {"id": "7000000000000000002", "name": "李四", "type": "p2p", "unread": 0, "muted": false,
       "last_message_preview": "", "last_message_time": 0, "last_position": -1, "rank_time": 0}
    ]
    """
    let chats = try BackendJSON.decoder.decode([Chat].self, from: data(json))

    #expect(chats.count == 2)
    #expect(chats[0].id == "7000000000000000001")
    #expect(chats[0].type == .group)
    #expect(chats[0].unread == 3)
    #expect(chats[0].muted)
    #expect(chats[0].lastMessagePreview == "张三: 明天开会")
    #expect(chats[0].lastMessageTime == 1_790_000_000)
    #expect(chats[0].lastPosition == 41)
    #expect(chats[0].rankTime == 1_790_000_005)
    #expect(chats[1].type == .p2p)
    #expect(chats[1].lastPosition == -1)
}

@Test func decodesChatWithoutExtensionFields() throws {
    // 计划 4.4 节的最小字段集：后来加的 last_position / rank_time 缺失时不能解码失败
    let json = """
    {"id": "c1", "name": "群", "type": "group", "unread": 0, "muted": false,
     "last_message_preview": "hi", "last_message_time": 100}
    """
    let chat = try BackendJSON.decoder.decode(Chat.self, from: data(json))
    #expect(chat.lastPosition == -1)
    #expect(chat.rankTime == 100, "没有 rank_time 时按最后消息时间排序")
}

@Test func decodesMessages() throws {
    let json = """
    [
      {"id": "m1", "chat_id": "c1", "position": 7, "sender_id": "u1", "sender_name": "张三",
       "is_self": false, "create_time": 1790000000, "type": "text", "text": "你好\\n第二行",
       "badged": true, "at_me": true},
      {"id": "m2", "chat_id": "c1", "position": 8, "sender_id": "1", "sender_name": "系统消息",
       "is_self": false, "create_time": 1790000001, "type": "system", "text": "张三 started the group chat.",
       "badged": false, "at_me": false},
      {"id": "m3", "chat_id": "c1", "position": 9, "sender_id": "u2", "sender_name": "",
       "is_self": true, "create_time": 1790000002, "type": "sticker_from_the_future", "text": "[表情]"}
    ]
    """
    let messages = try BackendJSON.decoder.decode([Message].self, from: data(json))

    #expect(messages[0].chatID == "c1")
    #expect(messages[0].senderName == "张三")
    #expect(messages[0].text == "你好\n第二行")
    #expect(messages[0].atMe)
    #expect(!messages[0].isSystem)
    #expect(messages[1].isSystem)
    #expect(!messages[1].badged)
    #expect(messages[2].isSelf)
    #expect(messages[2].type == "sticker_from_the_future", "没见过的消息类型原样保留")
    #expect(messages[2].badged, "缺省 badged 为 true")
    #expect(!messages[2].atMe)
}

@Test func decodesStatus() throws {
    let online = try BackendJSON.decoder.decode(
        BackendStatus.self,
        from: data(#"{"state": "online", "user": {"id": "u_me", "name": "我"}, "last_error": null}"#))
    #expect(online.state == .online)
    #expect(online.user == User(id: "u_me", name: "我"))
    #expect(online.lastError == nil)

    let expired = try BackendJSON.decoder.decode(
        BackendStatus.self,
        from: data(#"{"state": "logged_out", "user": null, "last_error": "session is not valid"}"#))
    #expect(expired.state == .loggedOut)
    #expect(expired.user == nil)
    #expect(expired.lastError == "session is not valid")
}

@Test func decodesQRLoginPayloads() throws {
    let start = try BackendJSON.decoder.decode(QRLoginStart.self, from: data(#"{"qr_content": "{\"qrlogin\":{\"token\":\"abc\"}}"}"#))
    #expect(start.qrContent == #"{"qrlogin":{"token":"abc"}}"#)

    for (raw, expected) in [("idle", QRLoginStatus.idle), ("waiting", .waiting), ("scanned", .scanned),
                            ("success", .success), ("expired", .expired), ("failed", .failed)] {
        let poll = try BackendJSON.decoder.decode(QRLoginPoll.self, from: data(#"{"status": "\#(raw)"}"#))
        #expect(poll.status == expected)
    }
}

@Test func encodesSendBody() throws {
    let body = try BackendJSON.encoder.encode(SendMessageBody(text: "回复 \"一下\""))
    let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
    #expect(object == ["text": "回复 \"一下\""])
}
