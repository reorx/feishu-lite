import AppKit
import SwiftUI

struct ComposerView: View {
    @Bindable var conversation: Conversation

    @State private var inputHeight: CGFloat = ComposerTextView.minHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = conversation.sendError {
                HStack(spacing: 6) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("关闭", systemImage: "xmark") {
                        conversation.dismissSendError()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ComposerTextView(text: $conversation.draft, height: $inputHeight) {
                    Task { await conversation.send() }
                }
                .frame(height: inputHeight)
                .overlay(alignment: .topLeading) {
                    if conversation.draft.isEmpty {
                        Text("发消息，回车发送，Shift+回车换行")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, ComposerTextView.inset.width + 5)
                            .padding(.top, ComposerTextView.inset.height)
                            .allowsHitTesting(false)
                    }
                }
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator)
                }
                Button("发送", systemImage: "paperplane.fill") {
                    Task { await conversation.send() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSend)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var canSend: Bool {
        !conversation.isSending
            && !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 输入框。回车发送，Shift+回车换行；输入法候选词还没上屏时，回车只用来上屏。
/// SwiftUI 的 TextField / TextEditor 拿不到输入法的组字状态，所以包一层 NSTextView。
struct ComposerTextView: NSViewRepresentable {
    static let inset = CGSize(width: 4, height: 7)
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let minHeight: CGFloat = ceil(NSLayoutManager().defaultLineHeight(for: font)) + inset.height * 2
    static let maxHeight: CGFloat = 160

    @Binding var text: String
    @Binding var height: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.textContainerInset = Self.inset
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text
        textView.setAccessibilityLabel("消息输入框")

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            context.coordinator.updateHeight(of: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 组字过程中不能动内容，否则候选词会丢
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            context.coordinator.updateHeight(of: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updateHeight(of: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if textView.hasMarkedText() {
                return false
            }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }

        func updateHeight(of textView: NSTextView) {
            guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let content = ceil(layout.usedRect(for: container).height) + ComposerTextView.inset.height * 2
            let clamped = min(max(content, ComposerTextView.minHeight), ComposerTextView.maxHeight)
            if abs(parent.height - clamped) > 0.5 {
                parent.height = clamped
            }
        }
    }
}
