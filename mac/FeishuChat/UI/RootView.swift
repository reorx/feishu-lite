import FeishuChatCore
import SwiftUI

struct RootView: View {
    let appState: AppState
    let windows: WindowManager

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .frame(minWidth: 800, minHeight: 460)
            .background(WindowReader { windows.window = $0 })
            .onAppear { windows.openWindow = openWindow }
            .modifier(LogoutConfirmation(messages: appState.messages))
    }

    @ViewBuilder
    private var content: some View {
        if appState.status != nil {
            HStack(spacing: 0) {
                ModuleNavigation(appState: appState)
                Divider()
                // 条件分支销毁旧工作区，避免隐藏的 NSTextView 接收回车。
                switch appState.activeModule {
                case .messages:
                    MessagesWorkspace(appState: appState)
                case .email:
                    EmailWorkspace()
                }
            }
            .onAppear { appState.reevaluateViewing() }
        } else {
            BackendStartupView(state: appState.backendState, retry: appState.retryBackendInstallation)
        }
    }
}

private struct MessagesWorkspace: View {
    let appState: AppState

    var body: some View {
        if let status = appState.messages.status, status.state == .loggedOut {
            LoginView(login: appState.messages.login, sessionExpired: status.lastError != nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Messages")
        } else {
            MainView(appState: appState)
        }
    }
}

private struct ModuleNavigation: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            moduleButton(.messages, title: "Messages", icon: "bubble.left.and.bubble.right",
                         count: appState.unreadCounts.messages)
            moduleButton(.email, title: "Email", icon: "envelope", count: appState.unreadCounts.email)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .frame(width: 76)
        .background(.bar)
    }

    private func moduleButton(_ module: AppModule, title: String, icon: String, count: Int) -> some View {
        Button { appState.activeModule = module } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(height: 24)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                if count > 0 { UnreadBadge(count: count, muted: false) }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .foregroundStyle(appState.activeModule == module ? Color.accentColor : Color.secondary)
            .background(appState.activeModule == module ? Color.accentColor.opacity(0.12) : .clear,
                        in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(count > 0 ? "\(count) 条未读" : "没有未读")
        .accessibilityAddTraits(appState.activeModule == module ? [.isSelected] : [])
    }
}

/// B 阶段只交付模块外壳；邮箱配置与后端接入由后续阶段实现。
private struct EmailWorkspace: View {
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Label("Email", systemImage: "envelope")
                    .font(.headline)
                Text("邮箱尚未接入")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            ContentUnavailableView("邮箱阅读器待接入", systemImage: "envelope",
                                   description: Text("当前提供模块切换。邮箱配置与收件阅读将在后续阶段加入。"))
                .navigationTitle("Email")
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
    @Bindable var messages: MessagesState

    func body(content: Content) -> some View {
        content.confirmationDialog("退出聊天登录？", isPresented: $messages.isConfirmingLogout) {
            Button("退出登录", role: .destructive) {
                Task { await messages.logout() }
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
