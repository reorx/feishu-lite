import AppKit
import SwiftUI
import Testing
@testable import FeishuLiteCore
@testable import FeishuLiteState

/// 记下每个子视图最终被摆放的高度
@MainActor private final class HeightRecorder {
    var heights: [String: CGFloat] = [:]
}

private extension View {
    func recordHeight(_ name: String, into recorder: HeightRecorder) -> some View {
        background(GeometryReader { proxy in
            Color.clear
                .onAppear { MainActor.assumeIsolated { recorder.heights[name] = proxy.size.height } }
                .onChange(of: proxy.size.height) { _, height in MainActor.assumeIsolated { recorder.heights[name] = height } }
        })
    }
}

/// V1a-01：邮件头部里，主题（最少 1 行、最多 2 行）和地址块（最少几行、展开的抄送多 1 行）都能伸缩。
/// VStack 先量出理想高度，再按这个高度摆放时，把剩余高度对半分给弹性小的子视图；地址块弹性小但本身高，
/// 只分到一半，抄送被压回一行。头部改用 TopDownStack，按顺序分高度。这里用确定尺寸的子视图钉住这个行为。
@MainActor struct MailHeaderLayoutTests {
    @Test(arguments: [45.0, 72.0, 90.0, 450.0])
    func expandedAddressesCapOnlyOverflowingContent(contentHeight: Double) async throws {
        let recorder = HeightRecorder()
        let host = NSHostingView(rootView: CappedAddressLayout {
            Color.clear.frame(height:contentHeight)
            ScrollView { Color.clear.frame(height:contentHeight) }.recordHeight("scroll", into:recorder)
            Text("共 30 人，滚动查看全部").font(.caption)
                .frame(minWidth:0,maxWidth:.infinity,minHeight:0,maxHeight:.infinity,alignment:.topLeading)
                .clipped().recordHeight("hint", into:recorder)
        }.frame(width:300))
        let ideal = host.fittingSize
        host.frame = NSRect(origin:.zero,size:ideal)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(10)) }
        #expect(recorder.heights["scroll"] == CGFloat(min(contentHeight,72)))
        if contentHeight <= 72 {
            #expect(recorder.heights["hint"] == 0)
            #expect(ideal.height == CGFloat(contentHeight))
        } else {
            #expect((recorder.heights["hint"] ?? 0) > 0)
            #expect(ideal.height == 72 + 2 + (recorder.heights["hint"] ?? 0))
        }
    }

    @Test func addressTextReflowsAcrossTheScrollLimitWithoutRetainingOldHeight() {
        let values = (1...9).map { MailAddress(name:"收件人\($0)",address:"r\($0)@example.invalid") }
        let controller = NSHostingController(rootView: MailAddressScroll(values:values).font(.callout))
        let text = NSHostingController(rootView: Text(MailAddressList.full(values)).font(.callout))
        let hint = NSHostingController(rootView: Text("共 9 人，滚动查看全部").font(.caption))
        for width in [240.0, 620.0, 240.0, 620.0] {
            let proposal = CGSize(width:width,height:1000)
            let content = text.sizeThatFits(in:proposal).height
            let height = controller.sizeThatFits(in:proposal).height
            if width == 620 {
                #expect(content < 72)
                #expect(height == content)
            } else {
                #expect(content > 72)
                #expect(height == 72 + 2 + hint.sizeThatFits(in:proposal).height)
            }
        }
    }

    /// 和截断时的实测一致：主题 20–40，地址块 70–85，间距 8，理想高度 133
    private func header(_ recorder: HeightRecorder) -> some View {
        TopDownStack(spacing: 8) {
            Color.clear.frame(minHeight: 20, idealHeight: 40, maxHeight: 40).recordHeight("subject", into: recorder)
            Color.clear.frame(minHeight: 70, idealHeight: 85, maxHeight: 85).recordHeight("addresses", into: recorder)
        }
        .frame(width: 300)
    }

    @Test func placingAtItsOwnIdealHeightGivesEveryRowItsIdealHeight() async throws {
        let recorder = HeightRecorder()
        let host = NSHostingView(rootView: header(recorder))
        let ideal = host.fittingSize
        #expect(ideal.height == 133)
        // 外层的 VStack 也是这样：先量出头部的理想高度，再把头部摆进同样高的位置
        host.frame = NSRect(origin: .zero, size: ideal)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(recorder.heights == ["subject": 40, "addresses": 85])
    }

    @Test func minimumHeightStaysTheSumOfMinimums() {
        // 分栏用很窄的宽度、零高度询问最小高度。这里不能像 fixedSize 那样返回理想高度，否则会把分栏撑出窗口
        let controller = NSHostingController(rootView: TopDownStack(spacing: 8) {
            Color.clear.frame(minHeight: 20, idealHeight: 40, maxHeight: 40)
            Color.clear.frame(minHeight: 70, idealHeight: 85, maxHeight: 85)
        })
        #expect(controller.sizeThatFits(in: CGSize(width: 10, height: 0)).height == 98)
        #expect(controller.sizeThatFits(in: CGSize(width: 10, height: 1000)).height == 133)
    }

    @Test func shortOfHeightTheEarlierRowsKeepTheirs() async throws {
        let recorder = HeightRecorder()
        let host = NSHostingView(rootView: header(recorder))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 110)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        // 主题在前，先拿到 2 行；地址块只剩 62，退到自己的最小高度
        #expect(recorder.heights == ["subject": 40, "addresses": 70])
    }
}
