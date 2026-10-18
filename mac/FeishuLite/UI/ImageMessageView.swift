import AppKit
import FeishuLiteCore
import SwiftUI

struct ImageMessageView: View {
    let messageID: String
    let conversation: Conversation
    let isVisible: Bool

    @State private var image: NSImage?
    @State private var failure: ImageMessageFailure?
    @State private var attempt = 0
    @State private var preview: PreviewRequest?

    var body: some View {
        content
            // 只有进入 viewport 才下载，离开时取消（R5b）；attempt 变化时重新下载
            .task(id: isVisible ? attempt : nil) {
                if isVisible { await load() }
            }
            .sheet(item: $preview) { request in
                ImagePreview(image: request.image, windowSize: request.windowSize)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            // 按图片比例定框，scaledToFill 只在极端比例时裁掉多出的部分，不露底色
            let size = ImageMessageLayout.displaySize(for: image.size)
            Button {
                preview = PreviewRequest(image: image, windowSize: Self.currentWindowSize())
            } label: {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                    }
                    .contentShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help("点击查看大图")
            .accessibilityLabel("图片消息，点击查看大图")
        } else if let failure {
            HStack(spacing: 6) {
                Image(systemName: failure.canRetry ? "exclamationmark.triangle" : "photo")
                    .foregroundStyle(failure.canRetry ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                Text(failure.message)
                    .foregroundStyle(.secondary)
                // 已撤回、无法解码这类永久错误，重试也不会成功
                if failure.canRetry {
                    Button("重新加载") { attempt += 1 }
                        .controlSize(.small)
                        .fixedSize()
                }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: .rect(cornerRadius: 10))
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(width: ImageMessageLayout.placeholderSize.width, height: ImageMessageLayout.placeholderSize.height)
                .background(.quaternary, in: .rect(cornerRadius: 10))
                .accessibilityLabel("正在加载图片")
        }
    }

    @MainActor private func load() async {
        guard image == nil else { return }
        failure = nil
        do {
            let data = try await conversation.imageData(messageID: messageID)
            try Task.checkCancellation()
            guard let decoded = NSImage(data: data), decoded.isValid else {
                failure = .decodingFailed
                return
            }
            image = decoded
        } catch {
            guard !Task.isCancelled else { return }
            failure = ImageMessageFailure(error: error)
        }
    }

    /// 预览按打开时窗口的内容区定尺寸；拿不到窗口时按最小窗口算
    private static func currentWindowSize() -> CGSize {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.contentLayoutRect.size ?? CGSize(width: 800, height: 460)
    }
}

private struct PreviewRequest: Identifiable {
    let id = UUID()
    let image: NSImage
    let windowSize: CGSize
}

/// 大图预览。尺寸跟随所在窗口：按图片比例，四周留边，不超出窗口。
private struct ImagePreview: View {
    let image: NSImage
    @State var windowSize: CGSize

    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

    private static let headerHeight: CGFloat = 45
    private static let margin = CGSize(width: 80, height: 60)
    private static let minimumSize = CGSize(width: 360, height: 240)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("查看图片").font(.headline)
                Spacer()
                Button { zoom = max(1, zoom / 2) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(zoom == 1)
                .help("缩小")
                Button { zoom = min(8, zoom * 2) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(zoom == 8)
                .help("放大")
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.headerHeight)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                }
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            // 预览开着时用户改了窗口大小：只看挂着 sheet 的那个窗口
            guard let window = note.object as? NSWindow, window.attachedSheet != nil else { return }
            windowSize = window.contentLayoutRect.size
        }
    }

    /// 图片按比例放进“窗口减去留边”的范围，不放大；预览本身不小于 minimumSize，也不超出窗口
    private var frameSize: CGSize {
        let maxWidth = max(Self.minimumSize.width, windowSize.width - Self.margin.width)
        let maxHeight = max(Self.minimumSize.height, windowSize.height - Self.margin.height)
        let imageArea = CGSize(width: maxWidth, height: maxHeight - Self.headerHeight)
        let natural = image.size
        let scale = natural.width > 0 && natural.height > 0
            ? min(1, imageArea.width / natural.width, imageArea.height / natural.height) : 1
        let width = min(maxWidth, max(Self.minimumSize.width, natural.width * scale))
        let height = min(maxHeight, max(Self.minimumSize.height, natural.height * scale + Self.headerHeight))
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}
