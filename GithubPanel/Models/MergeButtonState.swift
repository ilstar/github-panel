import Foundation

enum MergeButtonState: Equatable {
    case markReady
    case enqueue
    case merge
    case enableAutoMerge
    case disableAutoMerge
    case queued
    case checksFailed
    case blocked(MergeBlockReason)
    case statusUnavailable
    case waitingForChecks
    case working

    static func resolve(for pr: PullRequestRow, isWorking: Bool) -> MergeButtonState {
        if isWorking { return .working }
        if pr.isDraft { return .markReady }
        if pr.status == .failure || pr.status == .error { return .checksFailed }
        if pr.isInMergeQueue { return .queued }
        if pr.canMergeImmediately { return pr.isMergeQueueEnabled ? .enqueue : .merge }
        if pr.isAutoMergeEnabled { return .disableAutoMerge }
        // Auto-merge never gets past a conflict, so the conflict is what the author needs to see.
        if pr.mergeStateStatus == "DIRTY" { return .blocked(.conflicts) }
        if pr.canEnableAutoMerge { return .enableAutoMerge }
        if pr.status == .pending { return .waitingForChecks }
        if pr.status == .unknown { return .statusUnavailable }
        return .blocked(MergeBlockReason(pr: pr))
    }

    var title: String {
        switch self {
        case .markReady:
            return "Mark ready"
        case .enqueue:
            return "Add to queue"
        case .merge:
            return "Merge"
        case .enableAutoMerge:
            return "Enable auto-merge"
        case .disableAutoMerge:
            return "Disable auto-merge"
        case .queued:
            return "Queued"
        case .checksFailed:
            return "Checks failed"
        case let .blocked(reason):
            return reason.title
        case .statusUnavailable:
            return "Status unavailable"
        case .waitingForChecks:
            return "Waiting for checks"
        case .working:
            return "Working..."
        }
    }

    var iconName: String {
        switch self {
        case .markReady:
            return "checkmark.circle"
        case .enqueue:
            return "arrow.right.to.line"
        case .merge:
            return "checkmark"
        case .enableAutoMerge:
            return "bolt"
        case .disableAutoMerge:
            return "xmark"
        case .queued:
            return "checkmark.circle"
        case .checksFailed:
            return "xmark"
        case .blocked, .statusUnavailable:
            return "minus.circle"
        case .waitingForChecks:
            return "clock"
        case .working:
            return "clock"
        }
    }

    var isClickable: Bool {
        switch self {
        case .markReady, .enqueue, .merge, .enableAutoMerge, .disableAutoMerge:
            return true
        case .queued, .checksFailed, .blocked, .statusUnavailable, .waitingForChecks, .working:
            return false
        }
    }

    /// The label, naming the merge method on a Merge button.
    func title(mergeMethod: MergeMethod) -> String {
        self == .merge ? mergeMethod.buttonTitle : title
    }

    /// Why the button does nothing, for its tooltip.
    var helpText: String? {
        switch self {
        case .checksFailed:
            return "One or more checks failed. Fix them to merge."
        case let .blocked(reason):
            return reason.explanation
        case .statusUnavailable:
            return "GitHub did not report the checks' status. Refresh to try again."
        case .waitingForChecks:
            return "Checks are still running."
        case .markReady, .enqueue, .merge, .enableAutoMerge, .disableAutoMerge, .queued, .working:
            return nil
        }
    }

    var hasHoverEffect: Bool {
        switch self {
        case .markReady, .enqueue, .merge, .enableAutoMerge, .disableAutoMerge, .queued:
            return true
        case .checksFailed, .blocked, .statusUnavailable, .waitingForChecks, .working:
            return false
        }
    }
}

/// Why GitHub will not merge a pull request, from its merge state and review verdict.
enum MergeBlockReason: Equatable {
    case conflicts
    case behindBase
    case changesRequested
    case needsApproval
    case branchRules
    case checkingMergeability
    case other

    init(pr: PullRequestRow) {
        switch pr.mergeStateStatus {
        case "DIRTY":
            self = .conflicts
        case "BEHIND":
            self = .behindBase
        case "BLOCKED":
            switch pr.reviewStatus.decision {
            case .changesRequested: self = .changesRequested
            case .reviewRequired: self = .needsApproval
            case .approved, nil: self = .branchRules
            }
        case "UNKNOWN":
            self = .checkingMergeability
        default:
            self = .other
        }
    }

    var title: String {
        switch self {
        case .conflicts: return "Merge conflict"
        case .behindBase: return "Out of date"
        case .changesRequested: return "Changes requested"
        case .needsApproval: return "Needs approval"
        case .branchRules: return "Blocked by rules"
        case .checkingMergeability: return "Checking merge"
        case .other: return "Not mergeable"
        }
    }

    var explanation: String {
        switch self {
        case .conflicts:
            return "This branch conflicts with the base branch. Resolve the conflicts to merge."
        case .behindBase:
            return "The base branch requires branches to be up to date. Update this branch to merge."
        case .changesRequested:
            return "A reviewer asked for changes. Address them and ask for another review."
        case .needsApproval:
            return "The base branch needs an approving review before this can merge."
        case .branchRules:
            return "The base branch's rules block merging, such as required checks, required reviewers, or unresolved conversations."
        case .checkingMergeability:
            return "GitHub is still working out whether this can merge. Refresh in a moment."
        case .other:
            return "GitHub reports that this pull request can't be merged."
        }
    }
}
