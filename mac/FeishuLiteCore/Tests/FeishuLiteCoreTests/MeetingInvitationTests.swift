import Foundation
import Testing
@testable import FeishuLiteCore

struct MeetingInvitationTests {
    private func message(_ text: String, type: String = "video_chat") -> Message {
        Message(id: "synthetic-meeting", chatID: "synthetic-chat", position: 1, senderID: "synthetic-user",
            senderName: "合成用户", isSelf: false, createTime: 0, type: type, text: text)
    }

    @Test func backendTopicNumberAndEntryContractParses() throws {
        // 与 backend/tests/test_render.py 的会议输出期望完全一致。
        let text = "[视频会议] 测试交付会议\n会议号：123 456 789\n入会入口：https://vc.feishu.cn/w/123456789"
        let meeting = try #require(message(text).meetingInvitation)
        #expect(meeting.topic == "测试交付会议")
        #expect(meeting.number == "123456789")
        #expect(meeting.formattedNumber == "123 456 789")
        #expect(meeting.joinURL.absoluteString == "https://vc.feishu.cn/w/123456789")
        #expect(message(text, type: "text").meetingInvitation == nil)
    }

    @Test func backendNoTopicContractParsesWithoutInventingATopic() throws {
        let text = "[视频会议]\n会议号：123 456 789\n入会入口：https://vc.feishu.cn/w/123456789"
        let meeting = try #require(message(text).meetingInvitation)
        #expect(meeting.topic == nil)
        #expect(meeting.number == "123456789")
    }

    @Test func placeholderAndMissingOrInvalidPublicNumberFallBackToText() {
        for text in ["[视频会议]", "[视频会议]\n入会入口：https://vc.feishu.cn/w/",
            "[视频会议] 测试会议\n入会入口：https://vc.feishu.cn/w/",
            "[视频会议] 测试会议\n会议号：9000000000000000001\n入会入口：https://vc.feishu.cn/w/",
            "[视频会议] 测试会议\n会议号：abc\n入会入口：https://vc.feishu.cn/w/"] {
            #expect(message(text).meetingInvitation == nil)
        }
    }

    @Test func malformedOrMismatchedEntryCannotBecomeAJoinButton() {
        for entry in ["https://example.invalid/w/123456789", "http://vc.feishu.cn/w/123456789",
            "https://vc.feishu.cn/w/987654321", "javascript:alert(1)", "https://vc.feishu.cn/w/123456789?redirect=evil"] {
            #expect(message("[视频会议] 测试会议\n会议号：123 456 789\n入会入口：\(entry)").meetingInvitation == nil)
        }
    }

    @Test func multilineTopicUsesFinalMetadataAndPreservesLeadingZeros() throws {
        let text = "[视频会议] 第一行\n会议号：标题的一部分\n第二行\n会议号：001 002 003\n入会入口：https://vc.feishu.cn/w/001002003"
        let meeting = try #require(message(text).meetingInvitation)
        #expect(meeting.topic == "第一行\n会议号：标题的一部分\n第二行")
        #expect(meeting.number == "001002003")
        #expect(meeting.formattedNumber == "001 002 003")
    }
}
