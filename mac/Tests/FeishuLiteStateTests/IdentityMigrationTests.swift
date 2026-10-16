import Foundation
import Testing
@testable import FeishuLiteState

struct IdentityMigrationTests {
    @Test func preservesNewPreferencesAndImportsOldOnlyOnce() {
        let name = "rename-test.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("new", forKey: "shared")
        IdentityMigration.migrate(defaults: defaults, legacy: ["shared": "old", "hidden": ["chat"], "receipt": true])
        #expect(defaults.string(forKey: "shared") == "new")
        #expect(defaults.stringArray(forKey: "hidden") == ["chat"])
        #expect(defaults.bool(forKey: "receipt"))
        defaults.removeObject(forKey: "hidden")
        IdentityMigration.migrate(defaults: defaults, legacy: ["hidden": ["chat"]])
        #expect(defaults.object(forKey: "hidden") == nil)
    }

    @Test func cleanInstallDoesNotImportLaterLegacyState() {
        let name = "rename-test.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        IdentityMigration.migrate(defaults: defaults, legacy: nil)
        IdentityMigration.migrate(defaults: defaults, legacy: ["hidden": ["old"]])
        #expect(defaults.object(forKey: "hidden") == nil)
    }
}
