import Testing
@testable import FeishuChatCore

private func msg(_ position: Int, sender: String, at time: Int, isSelf: Bool = false, type: String = "text") -> Message {
    Message(id: "m\(position)", chatID: "c1", position: position, senderID: sender, senderName: sender,
            isSelf: isSelf, createTime: time, type: type, text: "hi")
}

@Test func consecutiveMessagesFromSameSenderShareOneHeader() {
    let rows = MessageRow.rows(for: [
        msg(1, sender: "张三", at: 1000),
        msg(2, sender: "张三", at: 1030),
        msg(3, sender: "李四", at: 1060),
        msg(4, sender: "张三", at: 1090),
    ], chatType: .group)

    #expect(rows.map(\.showsSender) == [true, false, true, true])
    #expect(rows.map(\.showsTimestamp) == [true, false, false, false])
}

@Test func longPauseStartsANewGroupWithTimestamp() {
    let rows = MessageRow.rows(for: [
        msg(1, sender: "张三", at: 1000),
        msg(2, sender: "张三", at: 1000 + MessageRow.timestampGap + 1),
    ], chatType: .group)

    #expect(rows.map(\.showsTimestamp) == [true, true])
    #expect(rows.map(\.showsSender) == [true, true])
}

@Test func ownAndSystemMessagesNeverShowSender() {
    let rows = MessageRow.rows(for: [
        msg(1, sender: "我", at: 1000, isSelf: true),
        msg(2, sender: "系统消息", at: 1010, type: "system"),
        msg(3, sender: "张三", at: 1020),
    ], chatType: .group)

    #expect(rows.map(\.showsSender) == [false, false, true])
}

@Test func directChatHidesSenderNames() {
    let rows = MessageRow.rows(for: [msg(1, sender: "李四", at: 1000), msg(2, sender: "我", at: 1010, isSelf: true)],
                               chatType: .p2p)
    #expect(rows.map(\.showsSender) == [false, false])
    #expect(rows.map(\.id) == ["m1", "m2"])
}
