import AppKit
import FeishuLiteCore

@MainActor final class MailPlainScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Restore only after TextKit has a real viewport. Task.yield is not a layout barrier.
@MainActor final class MailPlainController {
    let scrollView = MailPlainScrollView()
    let textView = NSTextView()
    let token: MailRenderToken
    private let mail: MailState
    private var savedPosition: MailPlainPosition?
    private var observer: NSObjectProtocol?
    private var restored = false
    private var stopped = false
    private var layingOut = false
    private var layoutWidth: CGFloat = 0
    private static let margin = CGFloat(MailReaderLayout.horizontalMargin)
    // 上下边距参与位置换算：恢复和保存都以它为基准
    private static let inset = CGFloat(MailReaderLayout.verticalMargin)

    init(mail: MailState, content: String, token: MailRenderToken) {
        self.mail = mail
        self.token = token
        if mail.renderToken == token { savedPosition = mail.plainPositions.claim(token:token,content:content) }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.drawsBackground = false
        // 字号和行高与 HTML 外壳一致（14px、1.5 倍）
        let font = NSFont.systemFont(ofSize:CGFloat(MailReaderLayout.bodyFontSize))
        let paragraph = NSMutableParagraphStyle()
        let natural = font.ascender - font.descender + font.leading
        paragraph.lineSpacing = max(0, font.pointSize * CGFloat(MailReaderLayout.lineHeight) - natural)
        textView.font = font
        textView.textColor = .labelColor
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font:font,.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph]
        textView.textContainerInset = NSSize(width:Self.margin,height:Self.inset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // 宽度由 layoutBody 管：超过最大阅读宽度时文字列靠左，不再铺满
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        // 空正文不写占位文字：界面在上面叠一个居中的空态，这里仍提供显示证明
        textView.string = content
        textView.textStorage?.setAttributes(textView.typingAttributes,range:NSRange(location:0,length:(content as NSString).length))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onLayout = { [weak self] in self?.layoutBody() }
        observer = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,
            object:scrollView.contentView,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.savePosition() }
            }
    }

    func layoutBody() {
        guard !stopped, !layingOut, scrollView.contentSize.width > 40, scrollView.contentSize.height > 0,
              mail.renderToken == token else { return }
        layingOut = true
        defer { layingOut = false }
        let size = scrollView.contentSize
        let widthChanged = layoutWidth != size.width
        layoutWidth = size.width
        textView.setFrameSize(NSSize(width:size.width,height:max(size.height,textView.frame.height)))
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        let column = min(size.width - 2 * Self.margin,CGFloat(MailReaderLayout.maxReadingWidth))
        container.containerSize = NSSize(width:column,height:.greatestFiniteMagnitude)
        manager.ensureLayout(for:container)
        let height = max(size.height,manager.usedRect(for:container).maxY + 2 * Self.inset)
        textView.setFrameSize(NSSize(width:size.width,height:height))
        guard !restored || widthChanged else { return }
        if let position = savedPosition, manager.numberOfGlyphs > 0 {
            let character = min(position.character,(textView.string as NSString).length - 1)
            let glyph = manager.glyphIndexForCharacter(at:max(0,character))
            let line = manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
            let y = min(max(0,line.minY + Self.inset + position.lineOffset),max(0,height - size.height))
            scrollView.contentView.scroll(to:NSPoint(x:0,y:y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        let firstLayout = !restored
        restored = true
        // The current native document has been laid out and its saved position applied.
        if firstLayout { mail.bodyDidDisplay(token) }
    }

    private func savePosition() {
        // Initial layout and dismantling can emit a temporary top; neither may replace a location.
        guard restored, !stopped, !layingOut, mail.renderToken == token,
              scrollView.contentSize.height > 0, layoutWidth == scrollView.contentSize.width,
              let manager = textView.layoutManager,
              let container = textView.textContainer, manager.numberOfGlyphs > 0,
              var identity = mail.readerIdentity else { return }
        identity.messageID = token.identity.messageID
        guard identity == token.identity else { return }
        let top = scrollView.contentView.bounds.minY
        let point = NSPoint(x:0,y:max(0,top - Self.inset))
        let glyph = manager.glyphIndex(for:point,in:container)
        let line = manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
        let position = MailPlainPosition(character:manager.characterIndexForGlyph(at:glyph),
                                         lineOffset:top - line.minY - Self.inset)
        savedPosition = position
        mail.plainPositions.save(position,token:token)
    }

    func stop() {
        guard !stopped else { return }
        // Bounds notifications already captured the last valid location. Dismantling may clamp to top.
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        scrollView.onLayout = nil
        mail.bodyDidDisappear(token)
    }
}
