import Foundation

/// How GitHub merges a pull request. Raw values are GitHub's GraphQL names.
enum MergeMethod: String, CaseIterable, Identifiable {
    case merge = "MERGE"
    case squash = "SQUASH"
    case rebase = "REBASE"

    var id: String { rawValue }

    /// The REST API's name for it.
    var restValue: String { rawValue.lowercased() }

    /// The name in the Merge Method menu, like GitHub's merge button.
    var title: String {
        switch self {
        case .merge: return "Create a merge commit"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }

    /// The row's merge button.
    var buttonTitle: String {
        switch self {
        case .merge: return "Merge"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }
}

/// The merge methods a repository allows and the one GitHub suggests for the viewer.
struct RepositoryMergeMethods: Equatable {
    /// In GitHub's menu order. Never empty: GitHub requires a repository to allow at least one.
    var allowed: [MergeMethod] = [.merge]
    /// The method the viewer last used in this repository, or the repository's default.
    var suggested: MergeMethod = .merge

    init(allowed: [MergeMethod] = [.merge], suggested: MergeMethod = .merge) {
        self.allowed = allowed.isEmpty ? [.merge] : allowed
        self.suggested = suggested
    }

    /// The suggested method when the repository still allows it, otherwise the first allowed one.
    var defaultMethod: MergeMethod {
        allowed.contains(suggested) ? suggested : allowed[0]
    }
}
