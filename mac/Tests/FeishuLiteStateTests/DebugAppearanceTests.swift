import AppKit
import Testing
@testable import FeishuLiteState

@Suite @MainActor struct DebugAppearanceTests {
    @Test func parsesExplicitAppearanceWithoutMockMode() {
        #if DEBUG
        #expect(DebugAppearance.name(environment: ["FEISHU_LITE_APPEARANCE": "light"]) == .aqua)
        #expect(DebugAppearance.name(environment: ["FEISHU_LITE_APPEARANCE": "dark"]) == .darkAqua)
        #else
        #expect(DebugAppearance.name(environment: ["FEISHU_LITE_APPEARANCE": "light"]) == nil)
        #expect(DebugAppearance.name(environment: ["FEISHU_LITE_APPEARANCE": "dark"]) == nil)
        #endif
    }

    @Test func absentOrInvalidValueFollowsSystem() {
        #expect(DebugAppearance.name(environment: [:]) == nil)
        for raw in ["", "Dark", "system", " dark "] {
            #expect(DebugAppearance.name(environment: ["FEISHU_LITE_APPEARANCE": raw]) == nil)
        }
    }

    @Test func startupAppliesAppearanceToProvidedTarget() {
        var applied: [NSAppearance.Name?] = []
        DebugAppearance.apply(environment: ["FEISHU_LITE_APPEARANCE": "dark"]) {
            applied.append($0?.name)
        }
        DebugAppearance.apply(environment: [:]) { applied.append($0?.name) }
        #if DEBUG
        #expect(applied.count == 2)
        #expect(applied[0] == .darkAqua)
        #expect(applied[1] == nil)
        #else
        #expect(applied.isEmpty)
        #endif
    }
}
