import Foundation

struct PullRequestRow: Identifiable, Equatable {
    let id: String
    let nodeID: String
    let title: String
    let number: Int
    let repoFullName: String
    let htmlURL: URL
    let headSHA: String
    let status: CheckState
    let isDraft: Bool
    let isAutoMergeEnabled: Bool
    let canEnableAutoMerge: Bool
    let canDisableAutoMerge: Bool
    let isMergeQueueEnabled: Bool
    let isInMergeQueue: Bool
    let mergeStateStatus: String
    let updatedAt: Date

    var canMergeImmediately: Bool {
        status.isPassing
        && !isDraft
        && ["CLEAN", "HAS_HOOKS"].contains(mergeStateStatus)
    }
}

enum CheckState: String {
    case success
    case noChecks
    case failure
    case error
    case pending
    case unknown

    init(githubStatus: String?, hasCheckContexts: Bool? = nil) {
        switch githubStatus {
        case "SUCCESS", nil:
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
