import CoreImage.CIFilterBuiltins
import SwiftUI

struct LoginView: View {
    let login: LoginModel

    var body: some View {
        VStack(spacing: 20) {
            Text("登录飞书")
                .font(.title2.weight(.semibold))
            qrArea
                .frame(width: 240, height: 240)
            caption
                .frame(minHeight: 44, alignment: .top)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { login.begin() }
    }

    @ViewBuilder
    private var qrArea: some View {
        switch login.phase {
        case let .waiting(content):
            QRCodeView(content: content)
        case let .scanned(content):
            QRCodeView(content: content)
                .opacity(0.15)
                .overlay {
                    Label("已扫码", systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.green)
                }
        case .failed:
            Image(systemName: "qrcode")
                .font(.system(size: 80))
                .foregroundStyle(.tertiary)
        case .idle, .loading, .succeeded:
            ProgressView()
        }
    }

    @ViewBuilder
    private var caption: some View {
        switch login.phase {
        case .idle, .loading:
            Text("正在获取二维码…")
                .foregroundStyle(.secondary)
        case .waiting:
            Text("用手机飞书扫码登录")
                .foregroundStyle(.secondary)
        case .scanned:
            Text("请在手机上确认登录")
                .foregroundStyle(.secondary)
        case .succeeded:
            Text("登录成功，正在连接…")
                .foregroundStyle(.secondary)
        case let .failed(message):
            VStack(spacing: 10) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") { login.retry() }
            }
        }
    }
}

/// 把登录用的内容渲染成二维码。始终黑码白底，深色模式下手机也能扫。
private struct QRCodeView: View {
    let content: String

    var body: some View {
        Group {
            if let image = Self.render(content) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
            } else {
                Text("二维码生成失败")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.white, in: .rect(cornerRadius: 12))
        .accessibilityLabel("登录二维码")
    }

    private static func render(_ content: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
