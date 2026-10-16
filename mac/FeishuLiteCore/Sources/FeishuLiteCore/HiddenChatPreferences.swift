import Foundation

/// 仅保存本机列表偏好，不修改飞书服务端的会话或未读状态。
public struct HiddenChatPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(userID: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key(userID)) ?? [])
    }

    public func save(_ ids: Set<String>, userID: String) {
        defaults.set(ids.sorted(), forKey: key(userID))
    }

    private func key(_ userID: String) -> String {
        "hiddenChatIDs.\(userID)"
    }
}
