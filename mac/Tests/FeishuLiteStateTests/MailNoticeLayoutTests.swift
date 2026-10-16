import AppKit
import SwiftUI
import Testing
import FeishuLiteCore
@testable import FeishuLiteState

@MainActor private func noticeDescendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { noticeDescendants($0, of: type) }
}

@MainActor extension MailReaderTests {
    @Test(arguments: [CGSize(width: 723, height: 460), CGSize(width: 903, height: 628)], [1, 2048])
    func unknownDeliveryNoticeDoesNotOverlapInboxToolbar(size: CGSize, count: Int) async throws {
        let (mail, prefs, suite) = await reader()
        defer { prefs.removePersistentDomain(forName: suite); mail.stopReader() }
        await mail.waitForReaderWork()
        let receipts = Dictionary(uniqueKeysWithValues: (0..<count).map { index in
            let receipt = MailNotificationReceipt(id: "layout-intent-\(index)", accountID: "reader-account", uidvalidity: 77,
                                                  batchID: "layout-batch", members: ["mail-105"], handled: false,
                                                  acknowledged: false, createdAt: 0)
            return (receipt.id, receipt)
        })
        prefs.set(try JSONEncoder().encode(receipts), forKey: "mail-notification-receipts-v1")
        let center = NotificationCenterRecorder()
        let notifications = MailNotificationCoordinator(mail: mail,
            notifications: NotificationService(notificationCenter: center), preferences: prefs)
        defer { notifications.stop() }
        let host = NSHostingView(rootView: AnyView(EmailWorkspace(mail: mail, notifications: notifications, redetect: {})))
        defer { host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded() }
        host.frame = NSRect(origin: .zero, size: size)
        var normalNoticeHeight: CGFloat = 0
        for state in ["inbox", "body", "configuration", "recreated", "wrapped"] {
            if state == "body" { await mail.selectMessage("mail-105") }
            mail.showsConfiguration = state == "configuration"
            if state == "recreated" {
                host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
                host.rootView = AnyView(EmailWorkspace(mail: mail, notifications: notifications, redetect: {}))
            }
            if state == "wrapped" {
                // Stress multiline layout at the same supported width with
                // larger text, without changing copy or production state.
                host.rootView = AnyView(EmailWorkspace(mail: mail, notifications: notifications, redetect: {})
                    .environment(\.font, .system(size: 28)))
            }
            let bodyRequests = readerRequestCount("/mail-105")
            let listRequests = readerRequestCount("/mail/messages")
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let split = try #require(noticeDescendants(host, of: NSSplitView.self).first)
            let menu = try #require(noticeDescendants(host, of: NSPopUpButton.self).first)
            let splitFrame = split.convert(split.bounds, to: host)
            let menuFrame = menu.convert(menu.bounds, to: host)
            print("NOTICE-GEOMETRY", size, count, state, "split", splitFrame, "inbox", menuFrame)
            // A notice needs at least a native control row plus padding. Test
            // the actual AppKit split/menu, not a copy of the container tree.
            #expect(splitFrame.minY >= 48)
            if state == "inbox" { normalNoticeHeight = splitFrame.minY }
            if state == "wrapped" { #expect(splitFrame.minY > normalNoticeHeight) }
            #expect(menuFrame.minY >= splitFrame.minY)
            #expect(splitFrame.height >= 300)
            #expect(abs(splitFrame.maxY - host.bounds.maxY) < 1)
            #expect(readerRequestCount("/mail-105") == bodyRequests)
            #expect(readerRequestCount("/mail/messages") == listRequests)
        }
        #expect(notifications.uncertainDeliveryCount == count)
        #expect(center.posts.isEmpty)
        #expect(readerRequestCount("/read") == 0)
        #expect(readerRequestCount("/ack") == 0)
    }

    @Test func inboxWithoutNoticeKeepsItsFullHeightAcrossReconstruction() async throws {
        let (mail, prefs, suite) = await reader()
        defer { prefs.removePersistentDomain(forName: suite); mail.stopReader() }
        await mail.waitForReaderWork()
        let notifications = MailNotificationCoordinator(mail: mail,
            notifications: NotificationService(notificationCenter: NotificationCenterRecorder()), preferences: prefs)
        defer { notifications.stop() }
        let host = NSHostingView(rootView: AnyView(EmailWorkspace(mail: mail, notifications: notifications, redetect: {})))
        defer { host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded() }
        host.frame = NSRect(x: 0, y: 0, width: 723, height: 460)
        var initialMenu: CGRect?
        for _ in 0..<2 {
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let split = try #require(noticeDescendants(host, of: NSSplitView.self).first)
            let menu = try #require(noticeDescendants(host, of: NSPopUpButton.self).first)
            let menuFrame = menu.convert(menu.bounds, to: host)
            #expect(split.convert(split.bounds, to: host) == host.bounds)
            if let initialMenu { #expect(menuFrame == initialMenu) }
            else { initialMenu = menuFrame; #expect(menuFrame.minY < 48) }
            host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
            host.rootView = AnyView(EmailWorkspace(mail: mail, notifications: notifications, redetect: {}))
        }
    }
}
