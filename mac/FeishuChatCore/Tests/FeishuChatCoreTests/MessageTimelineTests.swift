import Testing
@testable import FeishuChatCore

private func msg(_ position: Int, id: String? = nil, text: String = "hi") -> Message {
    Message(id: id ?? "m\(position)", chatID: "c1", position: position, senderID: "u1", senderName: "张三",
            isSelf: false, createTime: 1000 + position, type: "text", text: text)
}

@Test func mergeKeepsMessagesInPositionOrder() {
    var timeline = MessageTimeline()
    timeline.merge([msg(10), msg(11), msg(12)])
    timeline.merge([msg(7), msg(8), msg(9)])   // 往上翻到的更早一页
    timeline.merge([msg(13)])                  // 新到的推送

    #expect(timeline.messages.map(\.position) == Array(7...13))
    #expect(timeline.oldestPosition == 7)
    #expect(timeline.latestPosition == 13)
}

@Test func sameMessageFromSendResponseAndPushAppearsOnce() {
    var timeline = MessageTimeline()
    timeline.merge([msg(1), msg(2)])
    let sent = msg(3, id: "sent", text: "我发的")

    let changedBySendResponse = timeline.merge([sent])
    let changedByPush = timeline.merge([sent])
    #expect(changedBySendResponse)
    #expect(!changedByPush, "SSE 又推了一遍：没有变化")
    #expect(timeline.messages.map(\.id) == ["m1", "m2", "sent"])
}

@Test func mergeReplacesChangedMessageWithSameID() {
    var timeline = MessageTimeline()
    timeline.merge([msg(1, text: "旧")])
    let changed = timeline.merge([msg(1, text: "新")])
    #expect(changed)
    #expect(timeline.messages.map(\.text) == ["新"])
}

@Test func emptyTimelineHasNoBounds() {
    let timeline = MessageTimeline()
    #expect(timeline.isEmpty)
    #expect(timeline.oldestPosition == nil)
    #expect(timeline.latestPosition == nil)
}

@Test func pagingCursorWalksBackToTheBeginning() {
    // 首页：会话最新位置 49，一页 30 条 → 下一页从 20 之前开始
    var cursor = HistoryCursor(lastPosition: 49, pageSize: 30)
    #expect(cursor.hasMore)
    #expect(cursor.before == 20)

    cursor.advance()
    #expect(cursor.before == 0)
    #expect(!cursor.hasMore)
}

@Test func pagingCursorForShortOrEmptyChat() {
    #expect(!HistoryCursor(lastPosition: 12, pageSize: 30).hasMore)
    #expect(!HistoryCursor(lastPosition: -1, pageSize: 30).hasMore)
}
