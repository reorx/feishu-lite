import Foundation
import Testing
@testable import FeishuChatCore

@Test func oldImageMessagesAreViewableButRevokedImagesAreNot() throws {
    let json = #"{"id":"image-1","chat_id":"test-chat","position":0,"sender_id":"u1","sender_name":"测试","is_self":false,"create_time":1790000000,"type":"image","text":"[图片]"}"#
    var message = try BackendJSON.decoder.decode(Message.self, from: Data(json.utf8))
    #expect(message.isViewableImage)
    message.text = "[消息已撤回]"
    #expect(!message.isViewableImage)
    message.type = "text"
    message.text = "[图片]"
    #expect(!message.isViewableImage)
}
