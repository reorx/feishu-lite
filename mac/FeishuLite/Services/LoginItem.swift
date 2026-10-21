import ServiceManagement
import os

/// 开机启动（登录项），用 SMAppService 注册 App 自己
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled: Bool
    private let disabled: Bool

    init(disabled: Bool = false) {
        self.disabled = disabled
        isEnabled = disabled ? false : SMAppService.mainApp.status == .enabled
    }
    private(set) var lastError: String?

    private let log = Logger(subsystem: "com.reorx.FeishuLite", category: "login-item")

    func setEnabled(_ enabled: Bool) {
        guard !disabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            log.error("login item change failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
