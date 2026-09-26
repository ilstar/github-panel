import Foundation

enum PullRequestTab: String, CaseIterable, Identifiable {
    case open
    case reviews
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "My PRs"
        case .reviews: return "To Review"
        case .history: return "History"
        }
    }
}

enum PullRequestSelection {
    /// The pull request to show in the detail pane for the visible tab.
    static func reference(tab: PullRequestTab,
                          openRows: [PullRequestRow],
                          reviewRows: [ReviewRequestRow],
                          historyRows: [PullRequestHistoryRow],
                          selectedOpenID: String?,
                          selectedReviewID: String?,
                          selectedHistoryID: String?) -> PullRequestReference? {
        switch tab {
        case .open:
            return openRows.first { $0.id == selectedOpenID }?.reference
        case .reviews:
            return reviewRows.first { $0.id == selectedReviewID }?.reference
        case .history:
            return historyRows.first { $0.id == selectedHistoryID }?.reference
        }
    }
}
