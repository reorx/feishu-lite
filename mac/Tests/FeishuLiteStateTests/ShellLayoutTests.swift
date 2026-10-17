import AppKit
import SwiftUI
import Testing
import FeishuLiteCore
@testable import FeishuLiteState

/// 外壳把扫码页、能力检测页、更新后端页也放进了分栏。分栏会用很窄的宽度询问每一栏的最小高度，
/// 页面里只要有一段 `fixedSize(vertical:)` 的长文字，最小高度就会远超窗口，内容被推出窗口外（R7 实测过 1790pt）。
@MainActor struct ShellLayoutTests {
    private static let minimum = NSRect(x: 0, y: 0, width: 800, height: 460)

    private func app() -> (AppState, UserDefaults, String) {
        _ = NSApplication.shared
        let suite = "shell-layout-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let config = BackendConfig(uvPath: "", backendDir: "", externalEndpoint: nil, homeOverride: nil)
        let app = AppState(supervisor: BackendSupervisor(config: config),
                           notifications: NotificationService(badgeWriter: { _ in }, notificationCenter: NotificationCenterRecorder()),
                           windows: ShellWindows(), preferences: preferences)
        return (app, preferences, suite)
    }

    private func switcher(_ app: AppState) -> ModuleSwitcher {
        ModuleSwitcher(activeModule: app.activeModule, counts: UnreadCounts(messages: 120, email: 7), select: { _ in })
    }

    private func splitFrame(_ view: some View) async throws -> CGRect {
        let host = NSHostingView(rootView: AnyView(view))
        defer { host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded() }
        host.frame = Self.minimum
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let split = try #require(shellDescendants(host).first)
        return split.convert(split.bounds, to: host)
    }

    @Test(arguments: ["unknown", "unsupported", "unconfigured"])
    func emailPagesFitMinimumWindow(page: String) async throws {
        let (app, preferences, suite) = app()
        defer { preferences.removePersistentDomain(forName: suite) }
        if page != "unknown" {
            app.receiveStreamEvent(.status(BackendStatus(state: .online, features: page == "unsupported" ? [] : ["mail"])))
        }
        let view = EmailWorkspace(mail: app.mail, notifications: app.mailNotifications, redetect: {},
                                  sidebarVisibility: .constant(.all), switcher: switcher(app))
        #expect(try await splitFrame(view) == Self.minimum)
    }

    @Test(arguments: [ConnectionState.online, .loggedOut])
    func messagesPagesFitMinimumWindow(state: ConnectionState) async throws {
        let (app, preferences, suite) = app()
        defer { preferences.removePersistentDomain(forName: suite) }
        app.receiveStreamEvent(.status(BackendStatus(state: state, features: ["mail"])))
        for i in 0..<40 {
            app.messages.handle(.chatUpdated(Chat(id: "chat-\(i)", name: "合成会话 \(i)", type: .group, unread: i % 3,
                                                  muted: false, lastMessagePreview: "摘要", lastMessageTime: 1000 - i,
                                                  lastPosition: 1)))
        }
        let view = MainView(appState: app, sidebarVisibility: .constant(.all), switcher: switcher(app))
        #expect(try await splitFrame(view) == Self.minimum)
    }
}

@MainActor private func shellDescendants(_ view: NSView) -> [NSSplitView] {
    ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap { shellDescendants($0) }
}

private final class ShellWindows: AppWindows {
    var window: NSWindow? { nil }
    var isShowingContent: Bool { false }
    func show() {}
}
