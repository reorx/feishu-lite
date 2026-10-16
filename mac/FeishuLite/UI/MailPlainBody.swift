import SwiftUI

/// A selectable literal text document. The controller owns layout/restore, never a web renderer.
struct MailPlainBody: NSViewRepresentable {
    let mail: MailState
    let content: String
    let token: MailRenderToken

    func makeCoordinator() -> MailPlainController {
        MailPlainController(mail:mail,content:content,token:token)
    }
    func makeNSView(context:Context) -> MailPlainScrollView { context.coordinator.scrollView }
    func updateNSView(_ view:MailPlainScrollView,context:Context) {}
    static func dismantleNSView(_ view:MailPlainScrollView,coordinator:MailPlainController) { coordinator.stop() }
}
