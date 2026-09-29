import AppKit
import SwiftUI

/// 主窗口的显示状态，以及在窗口被关掉之后把它重新打开。
/// 关掉窗口 App 不退出，所以点通知或 Dock 图标时窗口可能不存在。
@MainActor
final class WindowManager {
    static let mainWindowID = "main"

    /// 主窗口出现时由 RootView 登记
    weak var window: NSWindow?
    /// SwiftUI 的开窗动作，由 RootView 首次出现时登记；窗口关掉之后仍然可用
    var openWindow: OpenWindowAction?

    /// 用户此刻是否看得到主窗口里的内容
    var isShowingContent: Bool {
        guard NSApp.isActive, let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible || window.isMiniaturized {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: Self.mainWindowID)
        }
    }
}
