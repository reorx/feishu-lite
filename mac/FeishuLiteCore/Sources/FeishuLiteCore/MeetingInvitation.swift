import Foundation

/// backend/render.py 的 _meeting_text 展示契约。格式不完整时返回 nil，由视图显示原文。
public struct MeetingInvitation: Equatable, Sendable {
    public let topic: String?
    /// 公开九位会议号，保留前导零；绝不使用内部 meetingId。
    public let number: String
    public let joinURL: URL
    public var formattedNumber: String {
        stride(from: 0, to: 9, by: 3).map { offset in
            String(number.dropFirst(offset).prefix(3))
        }.joined(separator: " ")
    }

    public init?(message: Message) {
        guard message.type == "video_chat" else { return nil }
        let lines = message.text.components(separatedBy: "\n")
        guard lines.count >= 3 else { return nil }
        // 主题允许换行，会议元数据只从末尾读取，避免把主题中的“会议号”当成字段。
        let title = lines.dropLast(2).joined(separator: "\n")
        guard title == "[视频会议]" || title.hasPrefix("[视频会议] ") else { return nil }
        let numberLine = lines[lines.count - 2]
        guard numberLine.hasPrefix("会议号：") else { return nil }
        let grouped = String(numberLine.dropFirst("会议号：".count))
        guard grouped.range(of: #"^[0-9]{3} [0-9]{3} [0-9]{3}$"#, options: .regularExpression) != nil else { return nil }
        let number = grouped.replacingOccurrences(of: " ", with: "")
        let entry = "https://vc.feishu.cn/w/\(number)"
        guard lines.last == "入会入口：\(entry)", let url = URL(string: entry) else { return nil }
        let topic = title.dropFirst("[视频会议]".count).trimmingCharacters(in: .whitespacesAndNewlines)
        self.topic = topic.isEmpty ? nil : topic
        self.number = number
        joinURL = url
    }
}

public extension Message {
    var meetingInvitation: MeetingInvitation? { MeetingInvitation(message: self) }
}
