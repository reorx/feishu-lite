import SwiftUI

@main
struct FeishuChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 单窗口。关掉窗口 App 不退出（见 AppDelegate），继续收消息弹通知
        Window("FeishuChat", id: WindowManager.mainWindowID) {
            RootView(appState: delegate.appState, windows: delegate.windows)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(appState: delegate.appState, loginItem: delegate.loginItem)
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
                appState.isConfirmingLogout = true
            }
            .disabled(!appState.isLoggedIn)
        }
    }
}
