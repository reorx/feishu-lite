import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let windows = WindowManager()
    let loginItem: LoginItem
    private let mockRuntime: MockRuntime?
    let appState: AppState

    override init() {
        let config = BackendConfig.load()
        let mock = config.mockDataDir == nil ? nil : MockRuntime()
        mockRuntime = mock
        if mock == nil { IdentityMigration.migrateStandardPreferences() }
        loginItem = LoginItem(disabled: mock != nil)
        let supervisor = BackendSupervisor(config: config)
        appState = AppState(supervisor: supervisor, notifications: mock?.notifications ?? NotificationService(),
                            windows: windows, preferences: mock?.preferences ?? .standard,
                            credentials: mock?.credentials)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugAppearance.apply()
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
        mockRuntime?.cleanup()
    }
}
