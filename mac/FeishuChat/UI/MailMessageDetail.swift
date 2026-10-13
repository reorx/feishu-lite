import FeishuChatCore
import SwiftUI
import WebKit

struct MailMessageDetail: View {
    let mail: MailState
    var body: some View {
        VStack(spacing:0) {
            if let row = mail.selectedSummary { MailMessageHeader(row:row); Divider() }
            if let warning = mail.readError {
                HStack {
                    Text("已读同步未完成。" + warning).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength:8)
                    Button("重试已读同步") { Task { await mail.retryRead() } }.disabled(mail.isReading || mail.status?.state != .online)
                }.padding(12)
            }
            if let warning = mail.routeError { Text(warning).foregroundStyle(.secondary).padding(12) }
            switch mail.bodyLoadState {
            case .idle:
                ContentUnavailableView("选择一封邮件",systemImage:"envelope.open")
            case .loading:
                ProgressView("正在读取正文…").frame(maxWidth:.infinity,maxHeight:.infinity)
            case let .failed(error):
                VStack(spacing:12) {
                    Label("正文未能显示",systemImage:"exclamationmark.triangle").font(.headline)
                    Text(error).foregroundStyle(.secondary)
                    Button("重试正文") { Task { await mail.selectMessage(mail.selectedMessageID) } }
                }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
            case let .loaded(body):
                MailBodyPresentation(mail:mail,mailBody:body)
                    .id("\(mail.selectedMessageID ?? ""):\(mail.readerGeneration)")
            }
            if let row = mail.selectedSummary, !row.attachments.isEmpty {
                Divider()
                MailAttachmentsView(attachments:row.attachments)
            }
        }
    }
}

private struct MailMessageHeader: View {
    let row: MailSummary
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:8) {
                Text(row.displaySubject).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text("发件人：" + addresses(row.sender)).textSelection(.enabled)
                Text("收件人：" + addresses(row.to)).textSelection(.enabled)
                if !row.cc.isEmpty { Text("抄送：" + addresses(row.cc)).textSelection(.enabled) }
                if row.receivedAt > 0 { Text(Date(timeIntervalSince1970:TimeInterval(row.receivedAt)),format:.dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary) }
            }.font(.callout).frame(maxWidth:.infinity,alignment:.leading).padding(16)
        }.frame(maxHeight:160)
    }
    private func addresses(_ values: [MailAddress]) -> String {
        values.isEmpty ? "未知" : values.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator:"、")
    }
}

private struct MailAttachmentsView: View {
    let attachments: [MailAttachment]
    var body: some View {
        DisclosureGroup("附件（\(attachments.count)） · 仅显示信息") {
            ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(Array(attachments.enumerated()),id:\.offset) { _, attachment in
                        VStack(alignment:.leading,spacing:3) {
                            Label(attachment.filename.isEmpty ? "未命名附件" : attachment.filename,systemImage:"paperclip").textSelection(.enabled)
                            Text(info(attachment)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:120)
        }.padding(12)
    }
    private func info(_ attachment: MailAttachment) -> String {
        guard let size = attachment.encodedSize else { return attachment.mediaType }
        return attachment.mediaType + " · " + (attachment.sizeIsApproximate ? "约 " : "") + ByteCountFormatter.string(fromByteCount:Int64(size),countStyle:.file)
    }
}

private struct MailBodyPresentation: View {
    let mail: MailState
    let mailBody: MailBody
    @State private var token: MailRenderToken?
    var body: some View {
        Group {
            if let token {
                if mailBody.kind == .html {
                    MailHTMLView(mail:mail,content:mailBody.content,token:token)
                } else {
                    MailPlainBody(mail:mail,content:mailBody.content,token:token)
                }
            } else { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
        }
        .onAppear { token = mail.beginBodyPresentation() }
        .onDisappear { if let token { mail.bodyDidDisappear(token) } }
    }
}

private struct MailPlainBody: View {
    let mail: MailState
    let content: String
    let token: MailRenderToken
    @State private var restoring = true
    private var paragraphs: [String] { content.isEmpty ? ["（正文为空）"] : content.components(separatedBy:"\n\n") }
    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:12) {
                        ForEach(Array(paragraphs.enumerated()),id:\.offset) { index, paragraph in
                            Text(verbatim:paragraph).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                                .id(String(index)).trackScrollRow(String(index),space:"mail-plain")
                        }
                    }.padding(20)
                }.coordinateSpace(name:"mail-plain")
                    .onPreferenceChange(VisibleScrollRows.self) { frames in
                        guard !restoring, let id = token.identity.messageID,
                              let first = VisibleScrollRows.first(in:frames,height:viewport.size.height) else { return }
                        mail.detailScrollAnchors[id] = first
                    }
                    .task {
                        await Task.yield()
                        if let id = token.identity.messageID, let anchor = mail.detailScrollAnchors[id] { proxy.scrollTo(anchor,anchor:.top) }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        restoring = false
                        mail.bodyDidDisplay(token) // the native body has appeared in this presentation
                    }
            }
        }
    }
}

private struct MailHTMLView: NSViewRepresentable {
    let mail: MailState
    let content: String
    let token: MailRenderToken
    func makeCoordinator() -> MailHTMLController { MailHTMLController(mail:mail,content:content,token:token) }
    func makeNSView(context:Context) -> WKWebView { context.coordinator.start(); return context.coordinator.webView }
    func updateNSView(_ view:WKWebView,context:Context) {}
    static func dismantleNSView(_ view:WKWebView,coordinator:MailHTMLController) { coordinator.stop() }
}
