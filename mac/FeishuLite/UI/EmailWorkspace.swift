import FeishuLiteCore
import SwiftUI

/// Email 工作区。检测能力和需要更新后端时也保留分栏，窗口结构和收件箱一致。
struct EmailWorkspace<Switcher: View>: View {
    let mail: MailState
    let notifications: MailNotificationCoordinator
    let redetect: () -> Void
    @Binding var sidebarVisibility: NavigationSplitViewVisibility
    let switcher: Switcher

    @Environment(\.today) private var today

    var body: some View {
        let status = mail.sidebarStatus(now: today)
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            ModuleSidebar(switcher: switcher) {
                if mail.capability == .supported {
                    MailInboxList(mail: mail, status: status)
                } else {
                    VStack(spacing: 0) {
                        SidebarHeader(status: status) { Text("收件箱") }
                        Divider()
                        Spacer(minLength: 0)
                    }
                }
            }
        } detail: {
            switch mail.capability {
            case .unknown:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在检测邮箱功能…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Email")
            case .unsupported:
                VStack(alignment: .leading, spacing: 16) {
                    Label("请更新邮箱后端", systemImage: "shippingbox").font(.title2)
                    Text("当前后端未提供邮箱功能。在终端重新安装后，再重新检测。")
                    BackendCommandView(value: BackendConfig.installationCommand)
                    Button("已安装，重新检测", action: redetect).buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: 580)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Email")
            case .supported:
                // 提示条放在详情栏顶部，占自己的高度，不压住侧栏和收件箱头部。
                VStack(spacing: 0) {
                    notificationNotice
                    supportedDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar { CollapsedSidebarStatus(status: status, visibility: $sidebarVisibility) }
    }

    @ViewBuilder private var supportedDetail: some View {
        if mail.status?.mailAccountID == nil || mail.showsConfiguration {
            VStack(spacing: 0) {
                if mail.status?.mailAccountID != nil {
                    HStack {
                        Button("返回阅读器", systemImage: "chevron.left") { mail.showsConfiguration = false }
                        Spacer()
                    }.padding(12)
                    Divider()
                }
                MailConfigurationView(mail: mail)
            }
            .navigationTitle("邮箱配置")
        } else {
            MailMessageDetail(mail: mail)
                .navigationTitle(mail.selectedMessageID == nil ? "Email" : mail.selectedSummary?.displaySubject ?? "Email")
        }
    }

    @ViewBuilder private var notificationNotice: some View {
        if notifications.uncertainDeliveryCount > 0 {
            NoticeBar(tone: .warning, systemImage: "bell.badge",
                      title: "有 \(notifications.uncertainDeliveryCount) 条邮件提醒的投递结果未确认",
                      message: "已保留待提醒邮件。再次提醒可能重复显示同一通知。",
                      action: InlineAction(title: "再次提醒", isEnabled: mail.isBackendReady,
                                           perform: notifications.retryUncertainDeliveries))
            Divider()
        } else if let failure = notifications.lastFailure {
            NoticeBar(tone: .error, systemImage: "bell.slash", title: failure,
                      action: InlineAction(title: "重试提醒", isEnabled: mail.isBackendReady,
                                           perform: notifications.request))
            Divider()
        }
    }
}

extension MailState {
    var canRefreshInbox: Bool { canSubmit && !isRefreshingReader }

    func refreshInbox() {
        Task { await sync(); await refreshReader() }
    }

    /// 侧栏状态行：连接状态一句话，地址和同步时间作次要信息，需要处理时附“检查配置”。
    func sidebarStatus(now: Date) -> SidebarStatus {
        switch capability {
        case .unknown: return SidebarStatus(tone: .neutral, text: "正在检测邮箱功能…")
        case .unsupported: return SidebarStatus(tone: .warning, text: "当前后端未提供邮箱功能")
        case .supported: break
        }
        var tone: SidebarStatusTone
        switch status?.state {
        case nil, .unconfigured: tone = .neutral
        case .online: tone = .healthy
        case .connecting, .offline: tone = .warning
        case .credentialMissing, .authFailed: tone = .error
        }
        var text = stateDescription
        if credentialIssue != nil { tone = .error }
        if hasUnsavedCredential {
            if tone != .error { tone = .warning }
            text += "，密码尚未安全保存"
        }
        var result = SidebarStatus(tone: tone, text: text, error: errorMessage)
        guard let status, status.mailAccountID != nil else { return result }
        var detail = [status.address ?? ""]
        if let time = status.lastSyncAt { detail.append("同步于 " + ChatTimeFormat.messageLabel(time, now: now)) }
        if status.unreadStale, status.state != .offline { detail.append("显示上次同步的缓存") }
        let joined = detail.filter { !$0.isEmpty }.joined(separator: " · ")
        result.detail = joined.isEmpty ? nil : joined
        if status.state == .credentialMissing || status.state == .authFailed || credentialIssue != nil || hasUnsavedCredential {
            result.action = InlineAction(title: "检查配置") { [self] in
                showsConfiguration = true
                invalidatePresentation()
            }
        }
        return result
    }
}

struct MailConfigurationView: View {
    @Bindable var mail: MailState
    @State private var confirmsRemoval = false

    private var isChangingAddress: Bool { mail.status?.mailAccountID == nil || mail.addressInput != mail.status?.address }

    var body: some View {
        Form {
            Section {
                TextField("邮箱地址", text: $mail.addressInput)
                    .textContentType(.emailAddress)
                SecureField("专用密码", text: $mail.passwordInput)
                    .textContentType(.password)
                Text("使用飞书生成的第三方客户端专用密码。连接固定为 imap.feishu.cn:993（TLS）。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("测试连接") { Task { await mail.testConnection() } }
                        .disabled(!mail.canSubmit || !mail.hasValidInput)
                    if isChangingAddress {
                        Button(mail.status?.mailAccountID == nil ? "保存邮箱" : "更换邮箱") { Task { await mail.saveAccount() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!mail.canSubmit || !mail.hasValidInput)
                    } else {
                        Button("更新专用密码") { Task { await mail.updateCredential() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!mail.canSubmit || mail.passwordInput.isEmpty)
                    }
                    if mail.operation != nil { ProgressView().controlSize(.small).accessibilityLabel("正在处理邮箱请求") }
                }
                if let result = mail.connectionTest {
                    Label(result.writable ? "连接成功，可同步已读状态" : "连接成功，但邮箱只读，无法同步已读状态",
                          systemImage: result.writable ? "checkmark.circle" : "exclamationmark.triangle")
                    Text("测试连接不会保存邮箱配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = mail.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            } header: {
                Text("飞书邮箱配置")
            } footer: {
                Text("邮箱与聊天扫码账号独立。退出聊天不会移除邮箱，切换聊天账号也不会切换邮箱。")
            }
            if mail.hasUnsavedCredential {
                Section("密码尚未安全保存") {
                    Text("本次可继续同步，但密码只留在内存；退出 App 后需要重新输入。")
                    if let issue = mail.credentialIssue { Text(issue.localizedDescription) }
                    Button("重试保存到钥匙串") { Task { await mail.retryCredentialSave() } }.disabled(!mail.canSubmit)
                }
            } else if let issue = mail.credentialIssue {
                Section("邮箱凭证") {
                    Text(issue.localizedDescription)
                    Button("重试读取钥匙串") { Task { await mail.retryKeychain() } }.disabled(!mail.canSubmit)
                }
            }
            if !mail.pendingCredentialDeletions.isEmpty {
                Section("旧邮箱清理未完成") {
                    Text(mail.cleanupError ?? "旧邮箱的钥匙串条目仍待清理。退出后会保留清理记录。")
                    Button("重试清理旧密码") { Task { await mail.retryCredentialCleanup() } }
                        .disabled(mail.operation != nil)
                }
            }
            if mail.status?.mailAccountID != nil {
                Section {
                    Button("移除邮箱", role: .destructive) { confirmsRemoval = true }.disabled(!mail.canSubmit)
                } footer: {
                    Text("移除邮箱将清除本机邮件缓存和此邮箱的钥匙串密码，聊天不受影响。")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("移除这个邮箱？", isPresented: $confirmsRemoval) {
            Button("移除邮箱", role: .destructive) { Task { await mail.removeAccount() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会停止邮件同步并清理本机缓存与密码；服务端邮件不受影响。")
        }
    }
}

/// 与启动引导共用安装命令展示。
struct BackendCommandView: View {
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            // 不用 fixedSize：放进分栏后，分栏会用很窄的宽度询问最小高度，把窗口撑高。
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
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
