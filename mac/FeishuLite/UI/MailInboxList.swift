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
                    if mail.folders.isEmpty { Text("正在获取文件夹…") }
                    ForEach(mail.folders) { folder in
                        Button(folderTitle(folder)) {}.disabled(!folder.supported || !folder.selectable || folder.id != "INBOX")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("收件箱")
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
                        if mail.nextCursor != nil {
                            Button("加载更早的邮件") { Task { await mail.loadNextPage() } }
                                .disabled(mail.isPaging || mail.isRefreshingReader)
                        }
                        if mail.isPaging { ProgressView().controlSize(.small).accessibilityLabel("正在加载更早的邮件") }
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
            if let error = mail.listError {
                VStack(alignment:.leading,spacing:6) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("重试加载收件箱") { mail.requestReaderRefresh() }.disabled(!mail.isBackendReady)
                }.padding(12)
            }
        }
    }
    private func folderTitle(_ folder: MailFolder) -> String {
        let label = folder.name == folder.id ? folder.name : "\(folder.name)（\(folder.id)）"
        return folder.id == "INBOX" && folder.supported && folder.selectable ? label : label + (folder.selectable ? " — 暂不支持读取" : " — 不可选择")
    }
    @ViewBuilder private var emptyState: some View {
        if mail.isRefreshingReader { ProgressView("正在读取收件箱…") }
        else if mail.status?.mailAccountID == nil { Text("配置邮箱后开始阅读").foregroundStyle(.secondary) }
        else if !mail.hasLoadedList { Text(mail.listError ?? "等待首次同步收件箱…").foregroundStyle(.secondary).padding(20) }
        else { Text("收件箱没有邮件").foregroundStyle(.secondary) }
    }
}

private struct MailSummaryRow: View {
    let row: MailSummary
    var body: some View {
        HStack(alignment:.top,spacing:8) {
            Circle().fill(row.unread ? Color.accentColor : Color.clear).frame(width:6,height:6).padding(.top,6)
            VStack(alignment:.leading,spacing:5) {
                HStack(alignment:.firstTextBaseline) {
                    Text(row.displaySender.isEmpty ? "未知发件人" : row.displaySender)
                        .font(.system(.body,weight:row.unread ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength:4)
                    if row.receivedAt > 0 { Text(Date(timeIntervalSince1970:TimeInterval(row.receivedAt)),format:.dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary) }
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
