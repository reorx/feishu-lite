import AppKit
import SwiftUI
import Testing
import FeishuLiteCore
@testable import FeishuLiteState

@MainActor private func descendantScrollView(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.lazy.compactMap { descendantScrollView($0) }.first
}

@MainActor extension MailReaderTests {
    private var plainContent: String {
        (0..<160).map { "纯文本段落 \($0): <script>literal</script> 合成阅读证据" }.joined(separator:"\n\n")
    }
    private func plainController(_ mail: MailState, content: String? = nil, width: CGFloat = 600) throws -> MailPlainController {
        let token = try #require(mail.beginBodyPresentation())
        let controller = MailPlainController(mail:mail,content:content ?? plainContent,token:token)
        controller.scrollView.frame = NSRect(x:0,y:0,width:width,height:400)
        controller.scrollView.layoutSubtreeIfNeeded()
        controller.layoutBody()
        return controller
    }
    private func scrollPlain(_ controller: MailPlainController, to y: CGFloat) {
        controller.scrollView.contentView.scroll(to:NSPoint(x:0,y:y))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
    }

    @Test func plainViewReconstructionKeepsTheVisibleParagraph() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let content = (0..<160).map { "纯文本段落 \($0): <script>literal</script> 合成阅读证据" }.joined(separator:"\n\n")
        let token = try #require(mail.beginBodyPresentation())
        let host = NSHostingView(rootView:AnyView(MailPlainBody(mail:mail,content:content,token:token)))
        defer { host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded() }
        host.frame = NSRect(x:0,y:0,width:600,height:400)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(descendantScrollView(host))
        try await waitReader { mail.displayedToken == token }
        scroll.contentView.scroll(to:NSPoint(x:0,y:750))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(100))
        let before = try #require(mail.plainPositions["mail-105"]?.position)
        #expect(before.character > 0)
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
        let returning = try #require(mail.beginBodyPresentation())
        let next = NSHostingView(rootView:AnyView(MailPlainBody(mail:mail,content:content,token:returning)))
        defer { next.rootView = AnyView(EmptyView()); next.layoutSubtreeIfNeeded() }
        next.frame = host.frame
        next.layoutSubtreeIfNeeded()
        try await waitReader { mail.displayedToken == returning }
        for _ in 0..<20 {
            next.layoutSubtreeIfNeeded()
            try await Task.sleep(for:.milliseconds(10))
        }
        let returnedScroll = try #require(descendantScrollView(next))
        #expect(abs(returnedScroll.contentView.bounds.minY - 750) < 1)
        #expect(mail.plainPositions["mail-105"]?.position == before)
        mail.bodyDidDisappear(returning)
    }

    @Test func plainNarrowAndWideLayoutKeepsTheSameTextLocation() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let content = (0..<120).map { "段落\($0) " + String(repeating:"长中文与 synthetic words 需要换行 ",count:8) }.joined(separator:"\n\n")
        let first = try plainController(mail,content:content,width:280)
        defer { first.stop() }
        scrollPlain(first,to:1200)
        let position = try #require(mail.plainPositions["mail-105"]?.position)
        let oldHeight = first.textView.frame.height
        first.scrollView.frame.size.width = 700
        first.scrollView.layoutSubtreeIfNeeded(); first.layoutBody()
        #expect(first.textView.frame.height < oldHeight)
        let manager = try #require(first.textView.layoutManager)
        let glyph = manager.glyphIndexForCharacter(at:position.character)
        let line = manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
        #expect(abs(first.scrollView.contentView.bounds.minY - (line.minY + 20 + position.lineOffset)) < 1)
        first.stop()
        let narrow = try plainController(mail,content:content,width:280)
        defer { narrow.stop() }
        #expect(abs(narrow.scrollView.contentView.bounds.minY - 1200) < 1)
    }

    @Test func plainNativeDocumentIsLiteralSelectableAndNeverAnEditor() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let content = "<script>literal</script> <img src='https://synthetic.invalid/image'>\nhttps://synthetic.invalid/link 2026-10-14"
        let controller = try plainController(mail,content:content)
        defer { controller.stop() }
        #expect(controller.textView.string == content)
        #expect(!controller.textView.isEditable)
        #expect(controller.textView.isSelectable)
        #expect(!controller.textView.isRichText)
        #expect(!controller.textView.isAutomaticLinkDetectionEnabled)
        #expect(!controller.textView.isAutomaticDataDetectionEnabled)
        controller.textView.setSelectedRange(NSRange(location:0,length:8))
        #expect(controller.textView.selectedRange() == NSRange(location:0,length:8))
        let storage = try #require(controller.textView.textStorage)
        storage.enumerateAttributes(in:NSRange(location:0,length:storage.length)) { attributes, _, _ in
            #expect(attributes[.link] == nil)
            #expect(attributes[.attachment] == nil)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named:name))
            appearance.performAsCurrentDrawingAppearance {
                #expect(controller.textView.textColor?.usingColorSpace(.deviceRGB) == NSColor.labelColor.usingColorSpace(.deviceRGB))
            }
        }
    }

    @Test func plainEmptyAndLongDocumentLayoutAndRestoreAreBounded() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let empty = try plainController(mail,content:"")
        // 空正文不写占位文字（界面叠一个居中的空态），但仍要给出显示证明
        #expect(empty.textView.string == "")
        #expect(mail.displayedToken == empty.token)
        #expect(empty.scrollView.contentView.bounds.minY == 0)
        empty.stop()
        let content = String(repeating:"合成长文本 <script>literal</script>\n",count:6000)
        let long = try plainController(mail,content:content,width:280)
        #expect(long.textView.string == content)
        #expect(long.textView.frame.height > 400)
        scrollPlain(long,to:80000)
        long.stop()
        let returned = try plainController(mail,content:content,width:280)
        defer { returned.stop() }
        #expect(abs(returned.scrollView.contentView.bounds.minY - 80000) < 1)
        #expect(mail.plainPositions.count == 1)
    }

    @Test func plainSwitchingTargetsAndRetiredCallbacksDoNotReplaceSavedPositions() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let first = try plainController(mail)
        defer { first.stop() }
        scrollPlain(first,to:750)
        let before = mail.plainPositions["mail-105"]?.position
        await mail.selectMessage("mail-104")
        let other = try plainController(mail)
        defer { other.stop() }
        scrollPlain(other,to:350)
        scrollPlain(first,to:0) // the retiring document's temporary top is not a user scroll
        first.stop()
        #expect(mail.plainPositions["mail-105"]?.position == before)
        #expect(mail.displayedToken == other.token)
        await mail.selectMessage("mail-105")
        let returned = try plainController(mail)
        defer { returned.stop() }
        #expect(abs(returned.scrollView.contentView.bounds.minY - 750) < 1)
        other.stop()
        #expect(mail.displayedToken == returned.token)
        let stale = MailPlainController(mail:mail,content:"旧正文",token:first.token)
        defer { stale.stop() }
        stale.scrollView.frame = returned.scrollView.frame
        stale.layoutBody()
        #expect(mail.plainPositions["mail-105"]?.owner == returned.token.presentation)
        #expect(mail.displayedToken == returned.token)
        #expect(first.scrollView.onLayout == nil)
    }

    @Test func plainInitialZeroViewportAndRetiredLayoutCannotProveDisplay() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let first = try plainController(mail)
        scrollPlain(first,to:750); first.stop()
        let location = mail.plainPositions["mail-105"]?.position
        let token = try #require(mail.beginBodyPresentation())
        let waiting = MailPlainController(mail:mail,content:plainContent,token:token)
        defer { waiting.stop() }
        waiting.layoutBody()
        #expect(mail.displayedToken == nil)
        #expect(mail.plainPositions["mail-105"]?.position == location)
        waiting.stop()
        waiting.scrollView.frame = NSRect(x:0,y:0,width:600,height:400)
        waiting.layoutBody()
        #expect(mail.displayedToken == nil)
        let returned = try plainController(mail)
        defer { returned.stop() }
        #expect(abs(returned.scrollView.contentView.bounds.minY - 750) < 1)
    }

    @Test func plainChangedContentAndConnectionStartAtTop() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        let first = try plainController(mail)
        scrollPlain(first,to:750); first.stop()
        let changed = try plainController(mail,content:"新正文\n\n" + plainContent)
        #expect(changed.scrollView.contentView.bounds.minY == 0)
        scrollPlain(changed,to:500)
        mail.invalidateReaderConnection()
        #expect(mail.plainPositions.count == 0)
        changed.stop()
        let next = try plainController(mail,content:"新正文\n\n" + plainContent)
        defer { next.stop() }
        #expect(next.scrollView.contentView.bounds.minY == 0)
    }

    @Test func plainCacheRejectsIdentityChangesAndLimitsLocationCount() {
        let cache = MailPlainPositionCache()
        let original = MailReaderIdentity(epoch:1,accountID:"synthetic-a",generation:1,uidvalidity:77,messageID:"synthetic-id")
        let variants = [original,
            MailReaderIdentity(epoch:2,accountID:"synthetic-a",generation:1,uidvalidity:77,messageID:"synthetic-id"),
            MailReaderIdentity(epoch:2,accountID:"synthetic-b",generation:1,uidvalidity:77,messageID:"synthetic-id"),
            MailReaderIdentity(epoch:2,accountID:"synthetic-b",generation:2,uidvalidity:77,messageID:"synthetic-id"),
            MailReaderIdentity(epoch:2,accountID:"synthetic-b",generation:2,uidvalidity:78,messageID:"synthetic-id")]
        for identity in variants {
            let token = MailRenderToken(identity:identity,selection:1,presentation:UUID())
            #expect(cache.claim(token:token,content:plainContent) == nil)
            cache.save(MailPlainPosition(character:20,lineOffset:3),token:token)
        }
        for index in 0..<20 {
            var identity = original; identity.messageID = "synthetic-\(index)"
            let token = MailRenderToken(identity:identity,selection:index,presentation:UUID())
            #expect(cache.claim(token:token,content:plainContent) == nil)
            cache.save(MailPlainPosition(character:20,lineOffset:3),token:token)
        }
        #expect(cache.count == 8)
        #expect(cache["synthetic-0"] == nil)
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test func plainRapidReconstructionAndLayoutStillUseTheVisibilityReadGate() async throws {
        let (mail,prefs,suite) = await reader()
        defer { prefs.removePersistentDomain(forName:suite); mail.stopReader() }
        await mail.selectMessage("mail-105")
        var module: AppModule = .messages
        mail.viewingContext = {
            ViewingContext(activeModule:module,isAppActive:true,isWindowVisible:true,
                           selectedChatID:nil,selectedMail:mail.displayedBodyRoute)
        }
        let token = try #require(mail.beginBodyPresentation())
        let first = MailPlainController(mail:mail,content:plainContent,token:token)
        defer { first.stop() }
        #expect(mail.displayedBodyRoute == nil)
        #expect(readerRequestCount("/read") == 0)
        first.scrollView.frame = NSRect(x:0,y:0,width:600,height:400)
        first.scrollView.layoutSubtreeIfNeeded(); first.layoutBody()
        #expect(mail.displayedToken == token)
        #expect(readerRequestCount("/read") == 0)
        module = .email; mail.reevaluateViewing()
        await mail.readTask?.value
        #expect(readerRequestCount("/read") == 1)
        scrollPlain(first,to:750)
        let original = mail.plainPositions["mail-105"]?.position
        first.stop()
        for _ in 0..<6 {
            let next = try plainController(mail)
            #expect(abs(next.scrollView.contentView.bounds.minY - 750) < 1)
            #expect(mail.plainPositions["mail-105"]?.position == original)
            first.layoutBody(); scrollPlain(first,to:0)
            #expect(mail.displayedToken == next.token)
            next.stop()
            #expect(mail.displayedBodyRoute == nil)
        }
        #expect(readerRequestCount("/read") == 1)
        #expect(readerRequestCount("/send") == 0)
    }
}
