import Foundation
import UserNotifications

enum NotificationPermission { case allowed, disabled, undecided }

struct LocalNotification {
    let id: String
    let title: String
    let body: String
    let threadID: String
    let userInfo: [String: String]
}

/// The same boundary wraps add, delivered/pending queries and exact removal.
@MainActor protocol LocalNotificationCenter {
    func authorization() async -> NotificationPermission
    func notifications() async -> [LocalNotification]
    func add(_ notification: LocalNotification) async throws
    func remove(_ ids: [String])
}

@MainActor final class SystemNotificationCenter: LocalNotificationCenter {
    private var center: UNUserNotificationCenter { .current() }
    func authorization() async -> NotificationPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied: return .disabled
        case .notDetermined: return .undecided
        default:
            return settings.alertSetting == .disabled && settings.notificationCenterSetting == .disabled ? .disabled : .allowed
        }
    }
    func notifications() async -> [LocalNotification] {
        let delivered = await center.deliveredNotifications().map(\.request)
        let pending = await center.pendingNotificationRequests()
        return (delivered + pending).map { request in
            LocalNotification(id:request.identifier, title:request.content.title, body:request.content.body,
                              threadID:request.content.threadIdentifier,
                              userInfo:request.content.userInfo.reduce(into:[:]) { result, entry in
                if let key = entry.key as? String, let value = entry.value as? String { result[key] = value }
            })
        }
    }
    func add(_ notification: LocalNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title; content.body = notification.body; content.sound = .default
        content.threadIdentifier = notification.threadID; content.userInfo = notification.userInfo
        try await center.add(UNNotificationRequest(identifier:notification.id,content:content,trigger:nil))
    }
    func remove(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers:ids)
        center.removePendingNotificationRequests(withIdentifiers:ids)
    }
}
