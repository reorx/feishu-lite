import Foundation
import Testing
@testable import FeishuChatCore

private func chat(_ id: String, rank: Int, unread: Int = 0, muted: Bool = false) -> Chat {
    Chat(id: id, name: id, type: .group, unread: unread, muted: muted, lastMessagePreview: "",
         lastMessageTime: rank, lastPosition: 0, rankTime: rank)
}

@Test func chatsAreOrderedByMostRecentActivity() {
    var list = ChatList()
    list.replaceAll([chat("a", rank: 100), chat("b", rank: 300), chat("c", rank: 200)])
    #expect(list.chats.map(\.id) == ["b", "c", "a"])
}

@Test func upsertMovesActiveChatToTop() {
    var list = ChatList()
    list.replaceAll([chat("a", rank: 100), chat("b", rank: 300)])

    list.upsert(chat("a", rank: 400, unread: 2))
    #expect(list.chats.map(\.id) == ["a", "b"])
    #expect(list["a"]?.unread == 2)

    list.upsert(chat("new", rank: 350))
    #expect(list.chats.map(\.id) == ["a", "new", "b"])
}

@Test func badgeCountSkipsMutedChats() {
    var list = ChatList()
    list.replaceAll([chat("a", rank: 1, unread: 2), chat("b", rank: 2, unread: 5, muted: true), chat("c", rank: 3, unread: 1)])
    #expect(list.badgeCount == 3)
}

@Test func listTimeLabels() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    func ts(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }
    let now = at(2026, 9, 29, 15, 30)

    #expect(ChatTimeFormat.listLabel(ts(at(2026, 9, 29, 9, 5)), now: now, calendar: calendar) == "09:05")
    #expect(ChatTimeFormat.listLabel(ts(at(2026, 9, 28, 23, 59)), now: now, calendar: calendar) == "昨天")
    #expect(ChatTimeFormat.listLabel(ts(at(2026, 3, 1, 8, 0)), now: now, calendar: calendar) == "3月1日")
    #expect(ChatTimeFormat.listLabel(ts(at(2025, 12, 31, 8, 0)), now: now, calendar: calendar) == "2025/12/31")
    #expect(ChatTimeFormat.listLabel(0, now: now, calendar: calendar) == "", "没有消息的会话不显示时间")

    #expect(ChatTimeFormat.messageLabel(ts(at(2026, 9, 29, 9, 5)), now: now, calendar: calendar) == "09:05")
    #expect(ChatTimeFormat.messageLabel(ts(at(2026, 9, 28, 23, 59)), now: now, calendar: calendar) == "昨天 23:59")
    #expect(ChatTimeFormat.messageLabel(ts(at(2026, 3, 1, 8, 0)), now: now, calendar: calendar) == "3月1日 08:00")
    #expect(ChatTimeFormat.messageLabel(ts(at(2025, 12, 31, 8, 0)), now: now, calendar: calendar) == "2025年12月31日 08:00")
}
