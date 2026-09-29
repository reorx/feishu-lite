import AppKit
import FeishuChatCore
import UserNotifications
import os

/// 本地通知和 Dock 角标
@MainActor
@Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let chatIDKey = "chat_id"
    private static let sessionExpiredID = "session-expired"
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.reorx.FeishuChat")!

    /// 用户在系统设置里关掉了通知（或者拒绝了授权弹窗）。这种情况下系统不会再弹授权，只能去系统设置里打开。
    private(set) var isDenied = false

    /// 用户点了某个会话的通知
    @ObservationIgnored var onOpenChat: ((String) -> Void)?
    /// 用户点了"登录已失效"的通知
    @ObservationIgnored var onOpenApp: (() -> Void)?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let log = Logger(subsystem: "com.reorx.FeishuChat", category: "notification")

    func activate() {
        center.delegate = self
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                log.notice("notification authorization granted: \(granted)")
            } catch {
                log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            await refreshAuthorization()
        }
    }

    /// 用户可能刚从系统设置回来，重新读一次授权状态
    func refreshAuthorization() async {
        let status = await center.notificationSettings().authorizationStatus
        isDenied = status == .denied
        log.notice("notification authorization status: \(status.rawValue)")
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    func notify(message: Message, chat: Chat) {
        let text = NotificationPolicy.content(message: message, chat: chat)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.threadIdentifier = chat.id
        content.userInfo = [Self.chatIDKey: chat.id]
        post(id: message.id, content: content)
    }

    func notifySessionExpired() {
        let content = UNMutableNotificationContent()
        content.title = "FeishuChat"
        content.body = "飞书登录已失效，请重新扫码"
        content.sound = .default
        post(id: Self.sessionExpiredID, content: content)
    }

    /// 会话已读之后，把通知中心里它的通知也清掉
    func clearNotifications(chatID: String) {
        Task {
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { $0.request.content.threadIdentifier == chatID }.map(\.request.identifier)
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    func clearSessionExpired() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.sessionExpiredID])
    }

    func setBadge(_ count: Int) {
        let label: String? = count <= 0 ? nil : count > 99 ? "99+" : String(count)
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
        }
    }

    private func post(id: String, content: UNNotificationContent) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            do {
                try await center.add(request)
                log.notice("posted notification \(id, privacy: .public)")
            } catch {
                log.error("failed to post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 要不要弹由 NotificationPolicy 在发之前决定；已经发出来的，App 在前台也照常显示
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let chatID = response.notification.request.content.userInfo[Self.chatIDKey] as? String
        await MainActor.run {
            if let chatID {
                onOpenChat?(chatID)
            } else {
                onOpenApp?()
            }
        }
    }
}
