import Foundation
import FeishuLiteCore

/// Business preferences never reach CFPreferences. Each runtime has its own memory,
/// so concurrent instances and abrupt process death need no disk cleanup.
@MainActor final class MockRuntime {
    let domain = "com.reorx.FeishuLite.mock.memory"
    let preferences: UserDefaults
    let credentials = EmptyMailCredentials()
    let notifications = NotificationService(silent: true, notificationCenter: SilentNotificationCenter())

    init() {
        preferences = MockPreferences(suiteName: domain)!
    }

    func cleanup() {
        for key in preferences.dictionaryRepresentation().keys { preferences.removeObject(forKey: key) }
    }
}

@MainActor struct EmptyMailCredentials: MailCredentialStore {
    func read(accountID: String) throws -> MailSecret { throw MailKeychainError.notFound }
    func write(_ secret: MailSecret, accountID: String, address: String) throws {}
    func delete(accountID: String) throws {}
}

@MainActor struct SilentNotificationCenter: LocalNotificationCenter {
    func authorization() async -> NotificationPermission { .allowed }
    func notifications() async -> [LocalNotification] { [] }
    func add(_ notification: LocalNotification) async throws {}
    func remove(_ ids: [String]) {}
}

/// UserDefaults-compatible storage for the getters used by AppState, hidden chats
/// and mail notification receipts. No standard-domain fallback or persistent writes.
final class MockPreferences: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func dictionaryRepresentation() -> [String: Any] { values }
    override func synchronize() -> Bool { true }
}
