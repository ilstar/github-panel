import Foundation

enum MergeButtonState: Equatable {
    case markReady
    case enqueue
    case merge
    case enableAutoMerge
    case disableAutoMerge
    case queued
    case checksFailed
    case blocked
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
        if pr.canEnableAutoMerge { return .enableAutoMerge }
        if pr.status == .pending { return .waitingForChecks }
        if pr.status == .unknown { return .statusUnavailable }
        return .blocked
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
        case .blocked:
            return "Not mergeable"
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

    var hasHoverEffect: Bool {
        switch self {
        case .markReady, .enqueue, .merge, .enableAutoMerge, .disableAutoMerge, .queued:
            return true
        case .checksFailed, .blocked, .statusUnavailable, .waitingForChecks, .working:
            return false
        }
    }
}
