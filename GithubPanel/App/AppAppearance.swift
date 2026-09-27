import AppKit

/// Light, dark, or whatever macOS is set to. Chosen in Settings and applied to every window.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "GithubPanel.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The appearance to force on the app, or nil to follow the system.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    /// The saved choice, or System when nothing valid is saved.
    static func stored(in defaults: DefaultsStoring = UserDefaults.standard) -> AppAppearance {
        defaults.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// Switches every window, including Settings, to this appearance.
    @MainActor
    func apply(to application: NSApplication = .shared) {
        application.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}
