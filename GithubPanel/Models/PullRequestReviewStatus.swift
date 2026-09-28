import Foundation

/// GitHub's review verdict for a pull request. GitHub only reports one when the base branch requires reviews.
enum ReviewDecision: String, Equatable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// Who has reviewed a pull request and who has yet to.
struct PullRequestReviewStatus: Equatable {
    var decision: ReviewDecision?
    /// Reviewers whose latest review approved.
    var approvedBy: [String] = []
    /// Reviewers whose latest review asked for changes.
    var changesRequestedBy: [String] = []
    /// Users and teams asked for a review who have not given one since.
    var waitingOn: [String] = []

    static let none = PullRequestReviewStatus()

    /// The tag on a My PRs row. Changes requested wins over an approval, like GitHub's verdict.
    var badge: ReviewBadge? {
        if decision == .changesRequested || !changesRequestedBy.isEmpty { return .changesRequested }
        if decision == .approved || (decision == nil && !approvedBy.isEmpty) { return .approved }
        if !waitingOn.isEmpty { return .awaitingReview }
        if decision == .reviewRequired { return .needsReview }
        return nil
    }

    /// One line per group of reviewers, for the tag's tooltip.
    var helpText: String? {
        var lines: [String] = []
        if !approvedBy.isEmpty { lines.append("Approved by \(approvedBy.joined(separator: ", ")).") }
        if !changesRequestedBy.isEmpty { lines.append("Changes requested by \(changesRequestedBy.joined(separator: ", ")).") }
        if !waitingOn.isEmpty { lines.append("Waiting on \(waitingOn.joined(separator: ", ")).") }
        if decision == .reviewRequired && approvedBy.isEmpty && waitingOn.isEmpty {
            lines.append("The base branch needs an approving review. Ask someone to review it.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

enum ReviewBadge: Equatable {
    case approved
    case changesRequested
    case awaitingReview
    case needsReview

    var title: String {
        switch self {
        case .approved: return "APPROVED"
        case .changesRequested: return "CHANGES REQUESTED"
        case .awaitingReview: return "AWAITING REVIEW"
        case .needsReview: return "NEEDS REVIEW"
        }
    }
}
