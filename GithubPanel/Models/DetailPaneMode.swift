import Foundation

/// How the pane on the right shows the selected pull request: the app's own views, or github.com in a web view.
/// Chosen in Settings.
enum DetailPaneMode: String, CaseIterable, Identifiable {
    case native
    case web

    static let defaultsKey = "GithubPanel.detailPaneMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: return "Native"
        case .web: return "GitHub.com"
        }
    }

    /// The saved choice, or Native when nothing valid is saved.
    static func stored(in defaults: DefaultsStoring = AppDefaults.store) -> DetailPaneMode {
        defaults.string(forKey: defaultsKey).flatMap(DetailPaneMode.init(rawValue:)) ?? .native
    }
}

extension PullRequestReference {
    /// The pull request's page on github.com.
    var webURL: URL {
        URL(string: "https://github.com/\(repoFullName)/pull/\(number)")!
    }
}
