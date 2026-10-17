import AppKit
import SwiftUI
import Testing
import FeishuLiteCore
@testable import FeishuLiteState

@MainActor private func noticeDescendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { noticeDescendants($0, of: type) }
}

/// 生产外壳传入的是真实切换控件；这里用同一个组件和固定计数，让侧栏头部高度和 App 一致。
@MainActor func emailWorkspace(_ mail: MailState, _ notifications: MailNotificationCoordinator) -> some View {
    EmailWorkspace(mail: mail, notifications: notifications, redetect: {}, sidebarVisibility: .constant(.all),
                   switcher: ModuleSwitcher(activeModule: .email, counts: UnreadCounts(messages: 3, email: 7), select: { _ in }))
}

/// 实际 AppKit 视图的位置：分栏、侧栏收件箱列表，以及详情区最上面的 AppKit 内容（正文或配置表单的滚动视图）。
/// U1-13 之后邮件头部是普通 SwiftUI 文字，不再有自己的滚动视图，所以正文状态下量到的是头部下方的正文。
/// 浮动侧栏盖在详情栏上，详情内容可以从 x=0 开始，所以按分栏的两个子视图区分，不按坐标。
@MainActor private struct NoticeGeometry {
    var split: CGRect
    var sidebarList: CGRect
    var detailTop: CGFloat?

    init(_ host: NSView) throws {
        let split = try #require(noticeDescendants(host, of: NSSplitView.self).first)
        self.split = split.convert(split.bounds, to: host)
        let panes = split.subviews.filter { $0.frame.width > 50 }.sorted { $0.frame.width < $1.frame.width }
        let sidebar = try #require(panes.first), detail = try #require(panes.last)
        try #require(sidebar !== detail)
        func scrolls(_ pane: NSView) -> [CGRect] {
            noticeDescendants(pane, of: NSScrollView.self).map { $0.convert($0.bounds, to: host) }.filter { $0.height > 0 }
        }
        sidebarList = try #require(scrolls(sidebar).max { $0.height < $1.height })
        detailTop = scrolls(detail).map(\.minY).min()
    }
}

@MainActor extension MailReaderTests {
    // U1-17：提示条移到详情栏顶部。分栏和侧栏不再被整体往下推，提示条在详情栏里占自己的高度，
    // 文字放大时跟着变高；仍然不额外请求正文或列表，也不 read/ack/投递（R3 的约束）。
    @Test(arguments: [CGSize(width: 800, height: 460), CGSize(width: 980, height: 628)], [1, 2048])
    func unknownDeliveryNoticeTakesDetailSpaceWithoutPushingSplit(size: CGSize, count: Int) async throws {
        let (mail, prefs, suite) = await reader()
        defer { prefs.removePersistentDomain(forName: suite); mail.stopReader() }
        await mail.waitForReaderWork()
        let quiet = MailNotificationCoordinator(mail: mail,
            notifications: NotificationService(notificationCenter: NotificationCenterRecorder()), preferences: prefs)
        let host = NSHostingView(rootView: AnyView(emailWorkspace(mail, quiet)))
        defer { host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded() }
        host.frame = NSRect(origin: .zero, size: size)
        // 没有提示时的基准：正文紧跟在按内容定高的头部下面；配置表单从详情顶部开始。
        await mail.selectMessage("mail-105")
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let baseline = try NoticeGeometry(host)
        let baselineTop = try #require(baseline.detailTop)
        #expect(baselineTop < 120)
        mail.showsConfiguration = true
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let configurationTop = try #require(try NoticeGeometry(host).detailTop)
        #expect(configurationTop < 20)
        mail.showsConfiguration = false
        print("NOTICE-BASELINE", size, count, "body", baselineTop, "configuration", configurationTop)
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
        quiet.stop()
        await mail.selectMessage(nil)

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
        host.rootView = AnyView(emailWorkspace(mail, notifications))
        var normalTop: CGFloat = 0
        for state in ["inbox", "body", "configuration", "recreated", "wrapped"] {
            if state == "body" { await mail.selectMessage("mail-105") }
            mail.showsConfiguration = state == "configuration"
            if state == "recreated" {
                host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
                host.rootView = AnyView(emailWorkspace(mail, notifications))
            }
            if state == "wrapped" {
                // Stress multiline layout at the same supported width with
                // larger text, without changing copy or production state.
                host.rootView = AnyView(emailWorkspace(mail, notifications).environment(\.font, .system(size: 28)))
            }
            let bodyRequests = readerRequestCount("/mail-105")
            let listRequests = readerRequestCount("/mail/messages")
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let geometry = try NoticeGeometry(host)
            print("NOTICE-GEOMETRY", size, count, state, "split", geometry.split, "list", geometry.sidebarList,
                  "detailTop", geometry.detailTop ?? -1)
            #expect(geometry.split == host.bounds)
            if state != "wrapped" { #expect(geometry.sidebarList == baseline.sidebarList) }
            if state != "inbox" {
                // A notice needs at least a native control row plus padding.
                let top = try #require(geometry.detailTop)
                #expect(top >= (state == "configuration" ? configurationTop : baselineTop) + 40)
                #expect(host.bounds.maxY - top >= 200)
                if state == "body" { normalTop = top }
                if state == "wrapped" { #expect(top > normalTop) }
            }
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
        let host = NSHostingView(rootView: AnyView(emailWorkspace(mail, notifications)))
        defer { host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded() }
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 460)
        await mail.selectMessage("mail-105")
        var initial: NoticeGeometry?
        for _ in 0..<2 {
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            let geometry = try NoticeGeometry(host)
            #expect(geometry.split == host.bounds)
            let top = try #require(geometry.detailTop)
            if let initial {
                #expect(geometry.sidebarList == initial.sidebarList)
                #expect(top == initial.detailTop)
            } else {
                initial = geometry
                // 正文紧跟在头部下面，头部按内容定高（U1-13），没有提示条占位
                #expect(top < 120)
            }
            host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
            host.rootView = AnyView(emailWorkspace(mail, notifications))
        }
    }
}
