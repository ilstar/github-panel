import Foundation

/// Identifies one pull request. Used as the value that opens a detail window.
struct PullRequestReference: Hashable, Codable, Identifiable {
    let repoFullName: String
    let number: Int

    var id: String { "\(repoFullName)#\(number)" }
}

extension PullRequestRow {
    var reference: PullRequestReference {
        PullRequestReference(repoFullName: repoFullName, number: number)
    }
}

extension PullRequestHistoryRow {
    var reference: PullRequestReference {
        PullRequestReference(repoFullName: repoFullName, number: number)
    }
}

struct PullRequestDetail: Equatable {
    enum State: Equatable {
        case open
        case draft
        case merged
        case closed
    }

    let reference: PullRequestReference
    /// The GraphQL node ID, used to mark files as viewed.
    let nodeID: String
    var title: String
    var body: String
    let authorLogin: String
    let state: State
    let baseRef: String
    let headRef: String
    /// The head commit. New review comments are posted against it.
    let headSHA: String
    let htmlURL: URL
    let createdAt: Date
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let commits: Int
    /// Whether the viewer authored the pull request and GitHub lets them edit its title and description.
    var canEdit = false
    /// Whether the viewer opened the pull request. GitHub does not let authors review their own.
    var isViewerAuthor = false
    /// Whether GitHub offers Update branch: the branch is behind its base, the viewer may update it,
    /// and the repository suggests updating branches or its rules require it.
    var canUpdateBranch = false
    /// When GitHub last changed the pull request. Compared with the list's `updatedAt` to tell whether a cached copy is stale.
    var updatedAt: Date?
    /// Who was asked to review and how each reviewer responded. Empty when GitHub does not return them.
    var reviewers = PullRequestReviewers.none
    /// Whether the viewer may request reviews: GitHub allows it with triage access or more, while the pull request is open.
    var canRequestReviewers = false

    var offersUpdateBranch: Bool { isViewerAuthor && canUpdateBranch }
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
    /// Whether the viewer marked this file as viewed on GitHub. A file changed since it was viewed is not viewed.
    var isViewed = false
    var codeOwners: [String] = []
    var isOwnedByViewer = false
}

/// A pull request's detail and changed files, loaded together for the detail window.
struct PullRequestDetailContent: Equatable {
    let detail: PullRequestDetail
    let files: [PullRequestFile]
}
