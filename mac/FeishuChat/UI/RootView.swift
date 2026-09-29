import SwiftUI

struct RootView: View {
    let appState: AppState
    let windows: WindowManager

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .frame(minWidth: 720, minHeight: 460)
            .background(WindowReader { windows.window = $0 })
            .onAppear { windows.openWindow = openWindow }
            .modifier(LogoutConfirmation(appState: appState))
    }

    @ViewBuilder
    private var content: some View {
        if let status = appState.status {
            if status.state == .loggedOut {
                LoginView(login: appState.login)
            } else {
                MainView(appState: appState)
            }
        } else {
            BackendStartupView(state: appState.backendState)
        }
    }
}

/// 还没连上本地后端时的占位
private struct BackendStartupView: View {
    let state: BackendSupervisor.State

    var body: some View {
        VStack(spacing: 12) {
            if case let .failed(message) = state {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                Text("日志：\(BackendSupervisor.logFileURL.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                ProgressView()
                Text("正在启动…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LogoutConfirmation: ViewModifier {
    @Bindable var appState: AppState

    func body(content: Content) -> some View {
        content.confirmationDialog("退出登录？", isPresented: $appState.isConfirmingLogout) {
            Button("退出登录", role: .destructive) {
                Task { await appState.logout() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除本机保存的登录凭证和消息缓存，下次使用需要重新扫码。")
        }
    }
}

/// 拿到承载这个视图的 NSWindow
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        ReaderView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow(window)
            }
        }
    }
}
