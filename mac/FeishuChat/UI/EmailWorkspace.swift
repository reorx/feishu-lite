import FeishuChatCore
import SwiftUI

struct EmailWorkspace: View {
    let mail: MailState
    let notifications: MailNotificationCoordinator
    let redetect: () -> Void

    var body: some View {
        // NavigationSplitView's native sidebar does not reserve an outer
        // safeAreaInset consistently. Give notices their own layout space.
        VStack(spacing: 0) {
            notificationNotice
                .fixedSize(horizontal: false, vertical: true)
            Group {
                switch mail.capability {
                case .unknown:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在检测邮箱功能…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                case .supported:
                    NavigationSplitView {
                        MailInboxList(mail: mail)
                            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                    } detail: {
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
                        } else {
                            MailMessageDetail(mail: mail)
                        }
                    }
                }
            }
        }
        .navigationTitle("Email")
    }

    @ViewBuilder private var notificationNotice: some View {
        if mail.capability == .supported, notifications.uncertainDeliveryCount > 0 {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("有 \(notifications.uncertainDeliveryCount) 条邮件提醒的投递结果未确认")
                        Text("已保留待提醒邮件。再次提醒可能重复显示同一通知。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("再次提醒", action: notifications.retryUncertainDeliveries)
                        .fixedSize()
                        .disabled(!mail.isBackendReady)
                }.padding(12)
                Divider()
            }
        } else if mail.capability == .supported, let failure = notifications.lastFailure {
            HStack(spacing: 16) {
                Text(failure).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("重试提醒", action: notifications.request).fixedSize().disabled(!mail.isBackendReady)
            }.padding(12)
        }
    }
}

struct MailSyncStatusView: View {
    let mail: MailState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mail.stateDescription).font(.caption)
            if let status = mail.status, status.mailAccountID != nil {
                Text(status.address ?? "").font(.caption).lineLimit(1).textSelection(.enabled)
                if status.unreadStale {
                    Label("显示上次同步的缓存与未读数", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                }
                if let time = status.lastSyncAt {
                    Text("最后同步：\(Date(timeIntervalSince1970: TimeInterval(time)).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if status.state == .credentialMissing || status.state == .authFailed || mail.credentialIssue != nil || mail.hasUnsavedCredential {
                    Button("检查邮箱配置") { mail.showsConfiguration = true; mail.invalidatePresentation() }
                }
            }
            if let error = mail.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
        }
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
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
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
