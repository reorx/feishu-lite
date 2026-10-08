import Foundation
import Testing
@testable import FeishuChatCore

private func sample(_ id: String, time: Int = 1) -> Chat {
    Chat(id: id, name: id, type: .p2p, unread: 3, muted: false,
         lastMessagePreview: "新消息", lastMessageTime: time)
}

@Test func hiddenChatsStayHiddenAfterMessagesRefreshAndRename() {
    var list = ChatList(hiddenIDs: ["a", "b"])
    list.replaceAll([sample("a"), sample("b"), sample("c")])
    var updated = sample("a", time: 100)
    updated.name = "改名后的会话"
    list.upsert(updated)
    #expect(list.visibleChats.map(\.id) == ["c"])
    #expect(list.hiddenChats.map(\.id) == ["a", "b"])
    list.replaceAll([updated, sample("c", time: 2)])
    list.upsert(sample("b", time: 200))
    #expect(list.visibleChats.map(\.id) == ["c"])
    #expect(list.hiddenChats.map(\.id) == ["b", "a"])
    #expect(list["a"]?.name == "改名后的会话")
    #expect(list.badgeCount == 9, "隐藏不改变未读和免打扰规则")
}

@Test func restoringChatsKeepsTheirLatestOrderAndUnread() {
    var list = ChatList(hiddenIDs: ["a", "b"])
    list.replaceAll([sample("a", time: 30), sample("b", time: 20), sample("c", time: 10)])
    list.hiddenIDs.subtract(["a", "b"])
    #expect(list.visibleChats.map(\.id) == ["a", "b", "c"])
    #expect(list.hiddenChats.isEmpty)
    #expect(list["a"]?.unread == 3)
}

@Test func hiddenPreferencesSurviveRelaunchAndAreIsolatedByAccount() throws {
    let suite = "HiddenChatsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = HiddenChatPreferences(defaults: defaults)
    preferences.save(["a", "b"], userID: "user-a")
    let relaunched = HiddenChatPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(relaunched.load(userID: "user-a") == ["a", "b"])
    #expect(relaunched.load(userID: "user-b").isEmpty)
    relaunched.save([], userID: "user-a")
    #expect(preferences.load(userID: "user-a").isEmpty)
}
