import CoreGraphics

/// 聊天里图片消息的显示尺寸：按图片实际比例，最长边不超过 maxEdge，不留底色。
public enum ImageMessageLayout {
    /// 显示框的最长边
    public static let maxEdge: CGFloat = 260
    /// 显示框的最短边：太小的图放大到这个尺寸，极端比例的图按它裁切，保证能点到
    public static let minEdge: CGFloat = 40
    /// 加载中和尺寸未知时的占位
    public static let placeholderSize = CGSize(width: 160, height: 100)

    public static func displaySize(for imageSize: CGSize) -> CGSize {
        let width = imageSize.width, height = imageSize.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return placeholderSize }
        // 大图等比缩到最长边，小图保持原尺寸；短边不足时等比放大，但不超过最长边
        var scale = min(1, maxEdge / max(width, height))
        scale = max(scale, min(minEdge / min(width, height), maxEdge / max(width, height)))
        let fitted = CGSize(width: width * scale, height: height * scale)
        // 极端比例时短边仍然不足，按最短边显示，多出的部分由视图裁掉
        return CGSize(width: max(fitted.width, minEdge), height: max(fitted.height, minEdge))
    }
}
