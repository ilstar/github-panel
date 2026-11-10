import Foundation

struct PullRequestRow: Identifiable, Equatable, Codable {
    let id: String
    let nodeID: String
    let title: String
    let number: Int
    let repoFullName: String
    let htmlURL: URL
    var headSHA: String
    var status: CheckState
    let isDraft: Bool
    let isAutoMergeEnabled: Bool
    let canEnableAutoMerge: Bool
    let canDisableAutoMerge: Bool
    let isMergeQueueEnabled: Bool
    let isInMergeQueue: Bool
    let mergeStateStatus: String
    let updatedAt: Date
    var reviewStatus: PullRequestReviewStatus = .none
    var mergeMethods = RepositoryMergeMethods()
    /// The branch this pull request merges into.
    var baseRefName: String?
    /// The pull request's branch, or nil when it lives in a fork, so another pull request can't be stacked on it.
    var headRefName: String?

    var canMergeImmediately: Bool {
        status.isPassing
        && !isDraft
        && ["CLEAN", "HAS_HOOKS"].contains(mergeStateStatus)
    }
}

enum CheckState: String, Codable {
    case success
    case noChecks
    case failure
    case error
    case pending
    case unknown

    /// GitHub reports no rollup at all when nothing runs on the head commit, so `nil` means no CI.
    init(githubStatus: String?, hasCheckContexts: Bool? = nil) {
        switch githubStatus {
        case nil:
            self = .noChecks
        case "SUCCESS":
            self = .success
        case "EXPECTED" where hasCheckContexts == false:
            self = .noChecks
        case "FAILURE":
            self = .failure
        case "ERROR":
            self = .error
        case "PENDING", "EXPECTED":
            self = .pending
        default:
            self = .unknown
        }
    }

    var emoji: String {
        switch self {
        case .success: return "✅"
        case .noChecks: return "➖"
        case .failure, .error: return "❌"
        case .pending: return "⏳"
        case .unknown: return "❔"
        }
    }

    var descriptionText: String {
        switch self {
        case .success: return "All checks are done."
        case .noChecks: return "No checks reported."
        case .failure, .error: return "Checks failed."
        case .pending: return "Still building."
        case .unknown: return "Status unavailable."
        }
    }

    var isPassing: Bool {
        self == .success || self == .noChecks
    }
}

/// Where a pull request stands, apart from its checks and reviews: the big icon on a My PRs row.
/// A conflict comes first because it is what the author has to fix, even on a draft.
enum PullRequestState: Equatable {
    case conflict
    case draft
    case queued
    case autoMerge
    case open

    init(_ pr: PullRequestRow) {
        if pr.mergeStateStatus == "DIRTY" {
            self = .conflict
        } else if pr.isDraft {
            self = .draft
        } else if pr.isInMergeQueue {
            self = .queued
        } else if pr.isAutoMergeEnabled {
            self = .autoMerge
        } else {
            self = .open
        }
    }

    var title: String {
        switch self {
        case .conflict: return "Merge conflict"
        case .draft: return "Draft"
        case .queued: return "In the merge queue"
        case .autoMerge: return "Auto-merge enabled"
        case .open: return "Open"
        }
    }
}
