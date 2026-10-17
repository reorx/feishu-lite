import FeishuLiteCore
import SwiftUI

@main
struct FeishuLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 单窗口。关掉窗口 App 不退出（见 AppDelegate），继续收消息弹通知
        Window("FeishuLite", id: WindowManager.mainWindowID) {
            RootView(appState: delegate.appState, windows: delegate.windows)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(appState: delegate.appState, loginItem: delegate.loginItem)
            ModuleCommands(appState: delegate.appState)
            SidebarCommands()
        }
    }
}

struct AppCommands: Commands {
    let appState: AppState
    let loginItem: LoginItem

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Toggle("开机启动", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            Button("退出登录…") {
                appState.messages.isConfirmingLogout = true
            }
            .disabled(!appState.messages.isLoggedIn)
        }
    }
}

/// 显示菜单：切换模块和刷新。侧栏收起时也能用。
struct ModuleCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            moduleToggle(.messages, title: "Messages", key: "1")
            moduleToggle(.email, title: "Email", key: "2")
            Divider()
            // 只有 Email 有刷新动作，在 Messages 里禁用
            Button("刷新") { appState.mail.refreshInbox() }
                .keyboardShortcut("r")
                .disabled(appState.status == nil || appState.activeModule != .email || !appState.mail.canRefreshInbox)
            Divider()
        }
    }

    private func moduleToggle(_ module: AppModule, title: String, key: KeyEquivalent) -> some View {
        Toggle(title, isOn: Binding(
            get: { appState.activeModule == module },
            set: { if $0 { appState.activeModule = module } }
        ))
        .keyboardShortcut(key)
        .disabled(appState.status == nil)
    }
}
