import Foundation
import FeishuLiteCore

/// One isolated preference domain per process/session; never inherit the standard app domain.
@MainActor final class MockRuntime {
    let domain = "com.reorx.FeishuLite.mock.\(UUID().uuidString)"
    let preferences: UserDefaults
    let credentials = EmptyMailCredentials()
    let notifications = NotificationService(silent: true, notificationCenter: SilentNotificationCenter())

    init() {
        preferences = UserDefaults(suiteName: domain)!
        preferences.removePersistentDomain(forName: domain)
    }

    func cleanup() {
        preferences.removePersistentDomain(forName: domain)
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
