import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let windows = WindowManager()
    let loginItem = LoginItem()
    let appState: AppState

    override init() {
        let supervisor = BackendSupervisor(config: .load())
        appState = AppState(supervisor: supervisor, notifications: NotificationService(), windows: windows)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点 Dock 图标：窗口关掉了就重新打开
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windows.show()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }
}
