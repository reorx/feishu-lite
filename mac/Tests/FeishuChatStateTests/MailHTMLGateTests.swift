import Foundation
import Testing
@testable import FeishuChatState

@Suite(.serialized) @MainActor struct MailHTMLGateTests {
    @Test func noFirstLoadBeforeProtectionAndFailureIsClosed() async {
        var loads: [String] = []
        var release: CheckedContinuation<Void, Error>?
        let gate = MailHTMLLoadGate(prepare:{ try await withCheckedThrowingContinuation { release = $0 } },load:{ loads.append($0) })
        let task = Task { await gate.start(document:"first") }
        while release == nil { await Task.yield() }
        #expect(loads.isEmpty)
        release!.resume(throwing:TestError.failed); await task.value
        #expect(loads.isEmpty)
        #expect(gate.state == .failed)
    }
    @Test func protectionThenLoadAndRetiredCompilerCannotLoad() async {
        var loads: [String] = []
        var release: CheckedContinuation<Void, Error>?
        let gate = MailHTMLLoadGate(prepare:{ try await withCheckedThrowingContinuation { release = $0 } },load:{ loads.append($0) })
        let task = Task { await gate.start(document:"old") }
        while release == nil { await Task.yield() }
        gate.stop(); release!.resume(); await task.value
        #expect(loads.isEmpty)
        let ready = MailHTMLLoadGate(prepare:{},load:{ loads.append($0) })
        await ready.start(document:"protected")
        #expect(loads == ["protected"])
        #expect(ready.state == .loaded)
    }
    enum TestError: Error { case failed }
    @Test func actualWKConfigurationAndBothDelegateRouterPathsAreIsolated() {
        let config = MailHTMLController.configuration()
        #expect(!config.websiteDataStore.isPersistent)
        #expect(!config.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!config.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(config.userContentController.userScripts.isEmpty)
        var opened: [URL] = []
        let router = MailNavigationRouter(openExternal:{ opened.append($0) })
        #expect(router.decide(url:URL(string:"about:blank"),userActivated:false,mainFrame:true,newWindow:false))
        #expect(!router.decide(url:URL(string:"about:blank"),userActivated:false,mainFrame:true,newWindow:false))
        #expect(!router.decide(url:URL(string:"https://synthetic.invalid"),userActivated:false,mainFrame:true,newWindow:false))
        #expect(!router.decide(url:URL(string:"file:///tmp/synthetic"),userActivated:true,mainFrame:true,newWindow:false))
        let link = URL(string:"http://intranet/path")!
        #expect(!router.decide(url:link,userActivated:true,mainFrame:true,newWindow:false))
        #expect(router.decide(url:link,userActivated:true,mainFrame:false,newWindow:true))
        router.popup(url:link,userActivated:true)
        router.popup(url:URL(string:"data:text/html,bad"),userActivated:true)
        router.popup(url:link,userActivated:false)
        #expect(opened == [link,link])
    }
}
