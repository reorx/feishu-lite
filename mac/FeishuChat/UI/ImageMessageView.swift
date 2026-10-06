import AppKit
import SwiftUI

struct ImageMessageView: View {
    let messageID: String
    let conversation: Conversation

    @State private var image: NSImage?
    @State private var error: String?
    @State private var attempt = 0
    @State private var showsPreview = false

    var body: some View {
        Group {
            if let image {
                Button { showsPreview = true } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 190)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击查看大图")
                .accessibilityLabel("图片消息，点击查看大图")
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text(error).font(.caption).multilineTextAlignment(.center)
                    Button("重新加载") { attempt += 1 }
                }
                .padding(12)
                .frame(width: 260, height: 190)
            } else {
                ProgressView("加载图片…")
                    .frame(width: 260, height: 190)
            }
        }
        .background(.quaternary, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .task(id: attempt) { await load() }
        .sheet(isPresented: $showsPreview) {
            if let image { ImagePreview(image: image) }
        }
    }

    @MainActor private func load() async {
        guard image == nil else { return }
        error = nil
        do {
            let data = try await conversation.imageData(messageID: messageID)
            try Task.checkCancellation()
            guard let decoded = NSImage(data: data), decoded.isValid else {
                error = "无法显示这张图片"
                return
            }
            image = decoded
        } catch {
            guard !Task.isCancelled else { return }
            if case BackendError.http(status: 404, detail: _) = error {
                self.error = "图片已撤回或不可用"
            } else {
                self.error = "图片加载失败，请重试"
            }
        }
    }
}

private struct ImagePreview: View {
    let image: NSImage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

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
            .padding(12)
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
        .frame(width: 800, height: 600)
    }
}
