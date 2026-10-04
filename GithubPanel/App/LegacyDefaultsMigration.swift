import Foundation

/// Versions through 2.5 used the bundle identifier `com.githubpanel.app`, so their settings, keyboard shortcut and
/// Sparkle state live in that defaults domain. On the first launch under the new identifier, copy them across once.
/// The old domain is left in place so going back to an older version still finds its settings.
enum LegacyDefaultsMigration {
    static let legacyDomain = "com.githubpanel.app"
    static let migratedKey = "GithubPanel.migratedLegacyDefaults"

    static func runIfNeeded() {
        guard !ProcessInfo.processInfo.isRunningTests else { return }
        migrate(from: UserDefaults.standard.persistentDomain(forName: legacyDomain), into: .standard)
    }

    /// Copies each legacy value the new domain does not already have, then marks the migration done.
    static func migrate(from legacy: [String: Any]?, into defaults: UserDefaults) {
        guard !defaults.bool(forKey: migratedKey) else { return }

        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migratedKey)
    }
}
