// 示例纯逻辑模块：FeishuChatCore 只放可单测的纯逻辑（状态机、编解码、数据模型），
// 禁止依赖 AppKit。确认分层跑通后可删除本文件及其测试。
public struct Greeting {
    public init() {}

    public func message(for name: String) -> String {
        "Hello, \(name)!"
    }
}
