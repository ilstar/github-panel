import Foundation

/// The verdict of a submitted review. Raw values are the REST API's review events.
enum PullRequestReviewEvent: String, CaseIterable, Identifiable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comment: return "Comment"
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        }
    }

    var explanation: String {
        switch self {
        case .comment: return "Leave feedback without approving."
        case .approve: return "Approve these changes for merging."
        case .requestChanges: return "Ask for changes that must be made before merging."
        }
    }

    /// GitHub refuses a comment or a change request without a message; an approval may be blank.
    var requiresBody: Bool {
        self != .approve
    }

    /// Shown once GitHub accepts the review.
    var confirmation: String {
        switch self {
        case .comment: return "You reviewed this pull request."
        case .approve: return "You approved this pull request."
        case .requestChanges: return "You requested changes on this pull request."
        }
    }
}

/// A review to submit in one step: the verdict, its message, and the commit it reviews.
struct NewPullRequestReview: Equatable {
    let event: PullRequestReviewEvent
    let body: String
    /// The head commit that was loaded, so the review is not applied to commits pushed since.
    let commitID: String
}
