import FeishuLiteCore
import SwiftUI

struct MailInboxList: View {
    let mail: MailState
    let status: SidebarStatus
    @State private var restoring = true
    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(status: status) {
                Menu {
                    folderMenu
                } label: {
                    HStack(spacing: 3) {
                        Text(MailFolderMenu.title(for: mail.selectedFolderID, in: mail.folders))
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("本期仅读取收件箱，其他文件夹暂不支持读取")
            } actions: {
                Button { mail.refreshInbox() } label: { Image(systemName:"arrow.clockwise") }
                    .help("刷新收件箱（⌘R）").accessibilityLabel("刷新收件箱")
                    .disabled(!mail.canRefreshInbox)
                Button { mail.showsConfiguration = true; mail.invalidatePresentation() } label: { Image(systemName:"gearshape") }
                    .help("邮箱配置").accessibilityLabel("邮箱配置")
            }
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    List(selection:Binding(get:{ mail.selectedMessageID },set:{ id in Task { await mail.selectMessage(id) } })) {
                        ForEach(mail.items) { row in
                            MailSummaryRow(row:row).tag(row.id).id(row.id).trackScrollRow(row.id,space:"mail-list")
                        }
                        // 列表为空时只显示空态，不和“正在加载更早的邮件”同时出现
                        if !mail.items.isEmpty, mail.nextCursor != nil || mail.isPaging { pagingRow }
                    }
                    .coordinateSpace(name:"mail-list")
                    .onPreferenceChange(VisibleScrollRows.self) { frames in
                        guard !restoring, let first = VisibleScrollRows.first(in:frames,height:viewport.size.height),
                              mail.listScrollAnchor != first else { return }
                        mail.listScrollAnchor = first
                    }
                    .onChange(of: mail.items.map(\.id)) { _, ids in
                        guard let anchor = mail.listScrollAnchor, ids.contains(anchor) else { return }
                        restoring = true
                        Task {
                            await Task.yield()
                            proxy.scrollTo(anchor,anchor:.top)
                            await Task.yield()
                            if !Task.isCancelled { restoring = false }
                        }
                    }
                    .task {
                        await Task.yield()
                        if let anchor = mail.listScrollAnchor { proxy.scrollTo(anchor,anchor:.top) }
                        await Task.yield()
                        if !Task.isCancelled { restoring = false }
                        if !mail.hasLoadedList { await mail.refreshReader() }
                    }
                    .overlay { if mail.items.isEmpty { emptyState } }
                }
            }
            // 列表为空时错误只在空态里显示；有缓存时才放在底部。刷新进行中不再留着上一次的错误。
            if let error = mail.listError, !mail.items.isEmpty {
                Divider()
                if mail.isRefreshingReader {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在刷新收件箱…").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    NoticeBar(tone: .warning, systemImage: "exclamationmark.triangle", title: error,
                              action: InlineAction(title: "重试", isEnabled: mail.isBackendReady) { mail.requestReaderRefresh() })
                        .font(.caption)
                        .controlSize(.small)
                }
            }
        }
    }

    /// 只显示名字，按层级缩进；当前文件夹打勾，暂不能读取的灰显，底部一行说明。
    @ViewBuilder private var folderMenu: some View {
        let entries = MailFolderMenu.entries(mail.folders)
        if entries.isEmpty { Text("正在获取文件夹…") }
        ForEach(entries) { entry in
            Toggle(isOn: Binding(get: { entry.id == mail.selectedFolderID }, set: { _ in })) {
                Text(String(repeating: "\u{2003}", count: entry.depth) + entry.title)
            }
            .disabled(!entry.isReadable)
        }
        if entries.contains(where: { !$0.isReadable }) {
            Divider()
            Text("暂只支持读取收件箱")
        }
    }

    /// 居中的无边框按钮；加载中换成一行进度。
    private var pagingRow: some View {
        Group {
            if mail.isPaging {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在加载更早的邮件…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                Button("加载更早的邮件") { Task { await mail.loadNextPage() } }
                    .buttonStyle(.borderless)
                    .disabled(mail.isRefreshingReader)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    /// 按错误状态选一种说法，不会出现“没有邮件”和错误提示同时显示。
    @ViewBuilder private var emptyState: some View {
        if mail.isRefreshingReader { ProgressView("正在读取收件箱…").controlSize(.small) }
        else if mail.status?.mailAccountID == nil { ListEmptyState(systemImage: "envelope", title: "配置邮箱后开始阅读") }
        else if let error = mail.listError {
            ListEmptyState(systemImage: "exclamationmark.triangle", title: error,
                           action: InlineAction(title: "重试", isEnabled: mail.isBackendReady) { mail.requestReaderRefresh() })
        }
        else if !mail.hasLoadedList { ListEmptyState(systemImage: "tray", title: "等待首次同步收件箱…") }
        else { ListEmptyState(systemImage: "tray", title: "收件箱没有邮件") }
    }
}

private struct MailSummaryRow: View {
    let row: MailSummary
    @Environment(\.today) private var today
    var body: some View {
        HStack(alignment:.top,spacing:8) {
            Circle().fill(row.unread ? Color.accentColor : Color.clear).frame(width:6,height:6).padding(.top,6)
            VStack(alignment:.leading,spacing:5) {
                HStack(alignment:.firstTextBaseline) {
                    Text(row.displaySender.isEmpty ? "未知发件人" : row.displaySender)
                        .font(.system(.body,weight:row.unread ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength:4)
                    if row.receivedAt > 0 { Text(ChatTimeFormat.listLabel(row.receivedAt,now:today)).font(.caption).foregroundStyle(.secondary) }
                }
                HStack(alignment:.top,spacing:6) {
                    Text(row.error == nil ? row.displaySubject : "邮件摘要暂时无法读取").lineLimit(2)
                    if !row.attachments.isEmpty { Image(systemName:"paperclip").foregroundStyle(.secondary).accessibilityLabel("包含附件") }
                }.font(.callout)
            }
        }.padding(.vertical,4)
            .accessibilityElement(children:.combine)
            .accessibilityValue(row.unread ? "未读" : "已读")
    }
}
