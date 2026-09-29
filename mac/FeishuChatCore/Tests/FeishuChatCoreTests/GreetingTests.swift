import Testing
@testable import FeishuChatCore

@Test func greetingMessage() {
    #expect(Greeting().message(for: "World") == "Hello, World!")
}
