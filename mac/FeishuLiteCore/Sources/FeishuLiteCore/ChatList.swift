import Foundation

/// 会话列表：按最近活跃排序，顺序和手机端一致
public struct ChatList: Equatable, Sendable {
    public private(set) var chats: [Chat] = []

    public var hiddenIDs: Set<String>

    public init(hiddenIDs: Set<String> = []) {
        self.hiddenIDs = hiddenIDs
    }

    public var visibleChats: [Chat] { chats.filter { !hiddenIDs.contains($0.id) } }
    public var hiddenChats: [Chat] { chats.filter { hiddenIDs.contains($0.id) } }

    public subscript(id: String) -> Chat? {
        chats.first { $0.id == id }
    }

    /// Dock 角标：免打扰会话不计
    public var badgeCount: Int {
        chats.lazy.filter { !$0.muted }.map(\.unread).reduce(0, +)
    }

    public mutating func replaceAll(_ newChats: [Chat]) {
        chats = Self.sorted(newChats)
    }

    public mutating func upsert(_ chat: Chat) {
        var updated = chats.filter { $0.id != chat.id }
        updated.append(chat)
        chats = Self.sorted(updated)
    }

    private static func sorted(_ chats: [Chat]) -> [Chat] {
        chats.sorted {
            ($0.rankTime, $0.lastMessageTime, $0.id) > ($1.rankTime, $1.lastMessageTime, $1.id)
        }
    }
}

public enum ChatTimeFormat {
    /// 会话列表右侧的时间：今天显示时分，昨天显示"昨天"，更早显示日期
    public static func listLabel(_ timestamp: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let day = dayLabel(date, now: now, calendar: calendar, otherYear: { "\($0)/\($1)/\($2)" })
        return day.isEmpty ? clock(date, calendar: calendar) : day
    }

    /// 消息上方的时间：总是带时分
    public static func messageLabel(_ timestamp: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let day = dayLabel(date, now: now, calendar: calendar, otherYear: { "\($0)年\($1)月\($2)日" })
        return day.isEmpty ? clock(date, calendar: calendar) : "\(day) \(clock(date, calendar: calendar))"
    }

    /// 今天返回空串
    private static func dayLabel(_ date: Date, now: Date, calendar: Calendar,
                                 otherYear: (Int, Int, Int) -> String) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        if days == 0 { return "" }
        if days == 1 { return "昨天" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let (year, month, day) = (parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        if year == calendar.component(.year, from: now) {
            return "\(month)月\(day)日"
        }
        return otherYear(year, month, day)
    }

    private static func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
