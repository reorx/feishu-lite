import Foundation
import Testing
@testable import FeishuLiteState
import FeishuLiteCore

@Suite @MainActor struct MockModeTests {
    @Test func mockOverridesExternalAndHome() {
        let config = BackendConfig.load(environment: ["FEISHU_LITE_MOCK_DATA": "/tmp/fixture",
            "FEISHU_LITE_HOME": "/real/home", "FEISHU_LITE_BACKEND_URL": "http://localhost:1234",
            "FEISHU_LITE_TOKEN": "real"])
        #expect(config.mockDataDir == "/tmp/fixture")
        #expect(config.externalEndpoint == nil)
        #expect(config.homeOverride == nil)
        #expect(config.backendArguments(port: 123).suffix(2) == ["--mock-data", "/tmp/fixture"])
    }

    @Test func emptyVariableDoesNotEnableMock() {
        #expect(BackendConfig.load(environment: ["FEISHU_LITE_MOCK_DATA": ""]).mockDataDir == nil)
    }

    @Test func relativePathUsesRepositoryRoot() {
        #expect(BackendConfig.resolveMockPath("mock-data/showcase", backendDir: "/repo/backend") == "/repo/mock-data/showcase")
    }

    @Test func assemblyIsIsolatedAndFresh() async throws {
        let first = MockRuntime()
        let second = MockRuntime()
        defer { first.cleanup(); second.cleanup() }
        first.preferences.set("email", forKey: "active-module")
        #expect(second.preferences.string(forKey: "active-module") == nil)
        #expect(first.preferences !== UserDefaults.standard)
        #expect(first.notifications.isSilent)
        first.notifications.activate()
        first.notifications.notifySessionExpired()
        first.notifications.setBadge(99)
        #expect(await first.notifications.localCenter.notifications().isEmpty)
        try first.credentials.write(MailSecret("fake"), accountID: "test", address: "test@example.com")
        #expect(throws: MailKeychainError.notFound) { try first.credentials.read(accountID: "test") }
        let login = LoginItem(disabled: true)
        login.setEnabled(true)
        #expect(!login.isEnabled)
    }
}
