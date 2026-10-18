import CoreGraphics
import Testing
@testable import FeishuLiteCore

/// U1-18：图片消息按实际比例显示，最长边不超过上限，不露底色。
struct ImageMessageLayoutTests {
    private func size(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        ImageMessageLayout.displaySize(for: CGSize(width: width, height: height))
    }

    @Test func largeImagesKeepTheirRatioWithinTheMaximumEdge() {
        let landscape = size(1200, 800)
        #expect(landscape.width == 260)
        #expect(abs(landscape.height - 173.33) < 0.01)

        let portrait = size(600, 1400)
        #expect(portrait.height == 260)
        #expect(abs(portrait.width - 111.43) < 0.01)

        #expect(size(800, 800) == CGSize(width: 260, height: 260))
    }

    @Test func smallImagesAreNotEnlarged() {
        #expect(size(60, 40) == CGSize(width: 60, height: 40))
        #expect(size(200, 120) == CGSize(width: 200, height: 120))
    }

    @Test func tinyImagesGetTheMinimumEdgeSoTheyStayClickable() {
        #expect(size(16, 16) == CGSize(width: 40, height: 40))
        // 等比放大到短边 40
        #expect(size(30, 20) == CGSize(width: 60, height: 40))
    }

    @Test func extremeRatiosClampTheShortEdgeAndCropInsteadOfLetterboxing() {
        // 全景图等比缩放后只有 32.5pt 高，短边按 40 显示，由视图裁切
        #expect(size(2400, 300) == CGSize(width: 260, height: 40))
        #expect(size(100, 3000) == CGSize(width: 40, height: 260))
    }

    @Test func emptyOrInvalidSizesFallBackToThePlaceholder() {
        #expect(size(0, 0) == ImageMessageLayout.placeholderSize)
        #expect(size(-5, 10) == ImageMessageLayout.placeholderSize)
        #expect(size(.nan, 10) == ImageMessageLayout.placeholderSize)
    }

    @Test func placeholderIsSmallerThanTheOldFixedFrame() {
        let placeholder = ImageMessageLayout.placeholderSize
        #expect(placeholder.width <= 160 && placeholder.height <= 100)
    }
}
