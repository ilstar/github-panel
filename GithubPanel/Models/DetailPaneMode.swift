import Foundation

/// Reads the legacy pane preference. Pull requests now always use the native pane.
enum DetailPaneMode: String, CaseIterable, Identifiable {
    case native

    static let defaultsKey = "GithubPanel.detailPaneMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: return "Native"
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
