import Foundation

/// The tabs of the Settings window, in toolbar order. The last tab opened is remembered.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case account
    case notifications
    case extensions
    case hooks

    static let defaultsKey = "GithubPanel.settingsTab"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .account: return "Account"
        case .notifications: return "Notifications"
        case .extensions: return "Extensions"
        case .hooks: return "Hooks"
        }
    }

    /// SF Symbol shown above the title in the Settings toolbar.
    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .account: return "person.crop.circle"
        case .notifications: return "bell.badge"
        case .extensions: return "puzzlepiece.extension"
        case .hooks: return "terminal"
        }
    }

    /// The saved tab, or General when nothing valid is saved.
    static func stored(in defaults: DefaultsStoring = AppDefaults.store) -> SettingsTab {
        defaults.string(forKey: defaultsKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }
}
