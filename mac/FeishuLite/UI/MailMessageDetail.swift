import FeishuLiteCore
import SwiftUI
import WebKit

/// 头部、附件和正文共用一个左边距，内容最宽到阅读宽度为止，宽窗口里靠左。
private let readerMargin = CGFloat(MailReaderLayout.horizontalMargin)
private let readerColumn = CGFloat(MailReaderLayout.maxReadingWidth) + 2 * readerMargin

struct MailMessageDetail: View {
    let mail: MailState
    var body: some View {
        VStack(spacing:0) {
            // 头部和附件先按内容取高度，剩下的给正文；不用 fixedSize，分栏按窄宽度询问最小高度时不会撑高窗口
            if let row = mail.selectedSummary { MailMessageHeader(row:row).id(row.id).layoutPriority(1); Divider() }
            if let warning = mail.readError {
                NoticeBar(tone:.warning,systemImage:"envelope.badge",title:"已读同步未完成",message:warning,
                          action:InlineAction(title:"重试已读同步",isEnabled:!mail.isReading && mail.status?.state == .online) {
                              Task { await mail.retryRead() }
                          })
                Divider()
            }
            if let warning = mail.routeError {
                NoticeBar(tone:.warning,systemImage:"exclamationmark.circle",title:warning)
                Divider()
            }
            switch mail.bodyLoadState {
            case .idle:
                ContentUnavailableView("选择一封邮件",systemImage:"envelope.open")
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            case .loading:
                ProgressView("正在读取正文…").frame(maxWidth:.infinity,maxHeight:.infinity)
            case let .failed(error):
                // 永久错误（解析失败、不支持的编码等）重试也不会成功，只说明原因
                ContentUnavailableView {
                    Label("正文未能显示",systemImage:"exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    if mail.canRetryBody {
                        Button("重试正文") { Task { await mail.selectMessage(mail.selectedMessageID) } }
                    }
                }
                // 撑满剩余高度，头部留在顶部，不随空态一起居中
                .frame(maxWidth:.infinity,maxHeight:.infinity)
            case let .loaded(body):
                MailBodyPresentation(mail:mail,mailBody:body)
                    .id("\(mail.selectedMessageID ?? ""):\(mail.readerGeneration)")
            }
            if let row = mail.selectedSummary, !row.attachments.isEmpty {
                Divider()
                MailAttachmentsView(attachments:row.attachments).id(row.id).layoutPriority(1)
            }
        }
    }
}

/// 高度跟随内容。收件人和抄送默认一行，人多时“等 N 人”，展开后超过上限才滚动。
private struct MailMessageHeader: View {
    let row: MailSummary
    /// 展开后超过这么多人才放进固定高度的滚动区
    private static let scrollingCount = 8
    @Environment(\.today) private var today
    @State private var expandsTo = false
    @State private var expandsCc = false

    var body: some View {
        TopDownStack(spacing:8) {
            Text(row.displaySubject)
                .font(.system(size:CGFloat(MailReaderLayout.subjectFontSize),weight:.semibold))
                .lineLimit(4)
                .textSelection(.enabled)
            TopDownStack(spacing:4) {
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    label("发件人")
                    sender.lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength:8)
                    if row.receivedAt > 0 {
                        Text(ChatTimeFormat.messageLabel(row.receivedAt,now:today))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                addressRow("收件人",row.to,expanded:$expandsTo)
                if !row.cc.isEmpty { addressRow("抄送",row.cc,expanded:$expandsCc) }
            }
        }
        .font(.callout)
        .padding(.horizontal,readerMargin)
        .padding(.top,14)
        .padding(.bottom,12)
        .frame(maxWidth:readerColumn,alignment:.leading)
        .frame(maxWidth:.infinity,alignment:.leading)
    }

    /// 标签列按最宽的“收件人”定宽，三行的内容左边对齐
    private func label(_ text: String) -> some View {
        ZStack(alignment:.leading) {
            Text("收件人").hidden()
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var sender: Text {
        guard row.sender.count == 1, let first = row.sender.first, !first.name.isEmpty else {
            return Text(MailAddressList.full(row.sender))
        }
        return Text(first.name) + Text(" <\(first.address)>").foregroundStyle(.secondary)
    }

    private func addressRow(_ title: String, _ values: [MailAddress], expanded: Binding<Bool>) -> some View {
        // 顶端对齐：滚动区没有文字基线，按基线对齐会让标签跑到底部的提示上
        HStack(alignment:.top,spacing:8) {
            label(title)
            if expanded.wrappedValue {
                VStack(alignment:.leading,spacing:2) {
                    if values.count > Self.scrollingCount {
                        ScrollView {
                            Text(MailAddressList.full(values)).textSelection(.enabled)
                                .frame(maxWidth:.infinity,alignment:.leading)
                        }
                        .scrollIndicators(.visible)
                        .frame(height:72)
                        Text("共 \(values.count) 人，滚动查看全部").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(MailAddressList.full(values)).textSelection(.enabled)
                    }
                    toggle("收起",title:title,expanded:expanded)
                }
            } else {
                Text(MailAddressList.collapsed(values)).lineLimit(1).textSelection(.enabled)
                if MailAddressList.isExpandable(values) { toggle("展开",title:title,expanded:expanded) }
            }
            Spacer(minLength:0)
        }
    }

    private func toggle(_ text: String, title: String, expanded: Binding<Bool>) -> some View {
        Button(text) { expanded.wrappedValue.toggle() }
            .buttonStyle(.link)
            .fixedSize()
            .accessibilityLabel(text + title)
    }
}

/// 附件少时全部列出，多时列前几个并给“还有 N 个”。每行一行字：图标、文件名、类型和大小。
private struct MailAttachmentsView: View {
    let attachments: [MailAttachment]
    @State private var showsAll = false
    private static let collapsedCount = 3
    /// 展开后超过这么多个才放进固定高度的滚动区
    private static let scrollingCount = 6

    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.firstTextBaseline,spacing:6) {
                Text("附件").font(.callout.weight(.semibold))
                Text("\(attachments.count) 个 · 仅显示信息").font(.caption).foregroundStyle(.secondary)
            }
            if attachments.count <= Self.collapsedCount {
                rows(attachments)
            } else if showsAll {
                if attachments.count > Self.scrollingCount {
                    ScrollView { rows(attachments).frame(maxWidth:.infinity,alignment:.leading) }
                        .scrollIndicators(.visible)
                        .frame(height:118)
                    Text("共 \(attachments.count) 个，滚动查看全部").font(.caption).foregroundStyle(.secondary)
                } else {
                    rows(attachments)
                }
                Button("收起") { showsAll = false }.buttonStyle(.link).font(.callout)
            } else {
                rows(Array(attachments.prefix(Self.collapsedCount)))
                Button("还有 \(attachments.count - Self.collapsedCount) 个") { showsAll = true }
                    .buttonStyle(.link)
                    .font(.callout)
                    .accessibilityLabel("显示其余 \(attachments.count - Self.collapsedCount) 个附件")
            }
        }
        .padding(.horizontal,readerMargin)
        .padding(.vertical,10)
        .frame(maxWidth:readerColumn,alignment:.leading)
        .frame(maxWidth:.infinity,alignment:.leading)
    }

    private func rows(_ items: [MailAttachment]) -> some View {
        VStack(alignment:.leading,spacing:4) {
            ForEach(Array(items.enumerated()),id:\.offset) { _, attachment in
                let name = attachment.filename.isEmpty ? "未命名附件" : attachment.filename
                HStack(spacing:8) {
                    Image(systemName:icon(attachment.kind))
                        .foregroundStyle(.secondary)
                        .frame(width:16)
                        .accessibilityHidden(true)
                    Text(name).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(name)
                    Spacer(minLength:8)
                    Text(info(attachment)).font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                }
                .font(.callout)
            }
        }
    }

    private func info(_ attachment: MailAttachment) -> String {
        guard let size = attachment.encodedSize else { return attachment.typeDescription }
        let amount = size < 1000 ? "\(size) 字节" : ByteCountFormatter.string(fromByteCount:Int64(size),countStyle:.file)
        return attachment.typeDescription + " · " + (attachment.sizeIsApproximate ? "约 " : "") + amount
    }

    private func icon(_ kind: MailAttachment.Kind) -> String {
        switch kind {
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .pdf: "doc.richtext"
        case .archive: "doc.zipper"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .text: "doc.plaintext"
        case .other: "doc"
        }
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
        // 空正文仍由正文视图完成布局并给出显示证明，空态只是叠在上面
        .overlay {
            if mailBody.content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("正文为空",systemImage:"doc.plaintext",description:Text("这封邮件没有文字内容。"))
                    .allowsHitTesting(false)
            }
        }
        .onAppear { token = mail.beginBodyPresentation() }
        .onDisappear { if let token { mail.bodyDidDisappear(token) } }
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

/// 竖排、靠左，从上到下依次分高度：每一行拿到剩下的全部高度，取自己需要的，余下的给后面的行。
/// VStack 按弹性从小到大、平分剩余高度。头部先按理想高度量好、再按这个高度摆放时，弹性小但本身高的
/// 地址块只分到一半，展开的抄送被压回一行（V1a-01）。按顺序分，摆放时每行都拿到量尺寸时的高度；
/// 零高度询问时每行仍取最小高度，分栏按窄宽度询问也不会被撑高（不是 fixedSize）。
struct TopDownStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = heights(width:proposal.width,height:proposal.height,subviews:subviews)
        let width = proposal.width ?? sizes.map(\.width).max() ?? 0
        return CGSize(width:width,height:sizes.map(\.height).reduce(0,+) + gaps(subviews))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (subview, size) in zip(subviews,heights(width:bounds.width,height:bounds.height,subviews:subviews)) {
            subview.place(at:CGPoint(x:bounds.minX,y:y),anchor:.topLeading,
                          proposal:ProposedViewSize(width:bounds.width,height:size.height))
            y += size.height + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { spacing * CGFloat(max(subviews.count - 1,0)) }

    private func heights(width: CGFloat?, height: CGFloat?, subviews: Subviews) -> [CGSize] {
        var remaining = height.map { $0 - gaps(subviews) }
        return subviews.map { subview in
            let size = subview.sizeThatFits(ProposedViewSize(width:width,height:remaining.map { max($0,0) }))
            remaining = remaining.map { $0 - size.height }
            return size
        }
    }
}
