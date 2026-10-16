import Foundation

/// Run before any model reads preferences. Keep the old domain intact for rollback.
enum IdentityMigration {
    private static let marker = "identity.feishuLite.preferencesMigrated"

    static func migrate(defaults: UserDefaults, legacy: [String: Any]?) {
        guard !defaults.bool(forKey: marker) else { return }
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: marker)
        defaults.synchronize()
    }

    static func migrateStandardPreferences() {
        migrate(defaults: .standard,
                legacy: UserDefaults.standard.persistentDomain(forName: "com.reorx.FeishuChat"))
    }
}
