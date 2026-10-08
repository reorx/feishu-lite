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
                LoginView(login: appState.login, sessionExpired: status.lastError != nil)
            } else {
                MainView(appState: appState)
            }
        } else {
            BackendStartupView(state: appState.backendState, retry: appState.retryBackendInstallation)
        }
    }
}

/// 还没连上本地后端时的占位
private struct BackendStartupView: View {
    let state: BackendSupervisor.State
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if case let .dependencyMissing(tool) = state {
                DependencyInstallationView(tool: tool, retry: retry)
            } else if case let .failed(message) = state {
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

private struct DependencyInstallationView: View {
    let tool: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("请先安装运行依赖", systemImage: "shippingbox")
                .font(.title2)
            Text("未检测到 \(tool)。FeishuChat 需要 Python 后端才能连接飞书。请打开「终端」，按顺序完成安装。")
            Text("1. 安装 uv 和 Git（已安装 Homebrew 时）")
            command("brew install uv git")
            Link("没有 Homebrew？查看安装方法", destination: URL(string: "https://brew.sh/zh-cn/")!)
            if tool != "uv" {
                Text("2. 安装后端及其 Python 依赖")
                command(BackendConfig.installationCommand)
                Text("uv 会自动安装 Python 3.12 和 larkx 等依赖。首次安装需要联网，可能需要几分钟。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("已安装，重新检测", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 600)
    }

    private func command(_ value: String) -> some View {
        HStack(alignment: .top) {
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
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
