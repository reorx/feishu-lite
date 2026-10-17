import Foundation

/// 图片视图在下载失败时用 init(error:)，NSImage 解码失败时用 decodingFailed。
/// Core 不依赖 AppKit，也不参与图片可见性、下载或取消任务的管理。
public struct ImageMessageFailure: Equatable, Sendable {
    public let message: String
    public let canRetry: Bool

    public static let decodingFailed = ImageMessageFailure(message: "无法显示这张图片", canRetry: false)

    public init(error: any Error) {
        message = BackendError.userMessage(for: error, action: .loadImage)
        if case BackendError.http(status: 404, detail: _) = error { canRetry = false }
        else { canRetry = true }
    }

    private init(message: String, canRetry: Bool) {
        self.message = message
        self.canRetry = canRetry
    }
}
