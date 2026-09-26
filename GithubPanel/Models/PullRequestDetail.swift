import Foundation

/// Identifies one pull request. Used as the value that opens a detail window.
struct PullRequestReference: Hashable, Codable, Identifiable {
    let repoFullName: String
    let number: Int

    var id: String { "\(repoFullName)#\(number)" }
}

struct PullRequestDetail: Equatable {
    enum State: Equatable {
        case open
        case draft
        case merged
        case closed
    }

    let reference: PullRequestReference
    let title: String
    let body: String
    let authorLogin: String
    let state: State
    let baseRef: String
    let headRef: String
    let htmlURL: URL
    let createdAt: Date
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let commits: Int
}

struct PullRequestFile: Identifiable, Equatable {
    enum Status: String, Equatable {
        case added
        case removed
        case modified
        case renamed
        case copied
        case changed
        case unchanged
    }

    var id: String { filename }
    let filename: String
    let previousFilename: String?
    let status: Status
    let additions: Int
    let deletions: Int
    /// Unified diff hunks. GitHub leaves this out for binary files and very large diffs.
    let patch: String?
}

/// A pull request's detail and changed files, loaded together for the detail window.
struct PullRequestDetailContent: Equatable {
    let detail: PullRequestDetail
    let files: [PullRequestFile]
}
