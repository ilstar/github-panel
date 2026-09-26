import Foundation

enum PullRequestTab: String, CaseIterable, Identifiable {
    case open
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "Open"
        case .history: return "History"
        }
    }
}

enum PullRequestSelection {
    /// The pull request to show in the detail pane for the visible tab.
    static func reference(tab: PullRequestTab,
                          openRows: [PullRequestRow],
                          historyRows: [PullRequestHistoryRow],
                          selectedOpenID: String?,
                          selectedHistoryID: String?) -> PullRequestReference? {
        switch tab {
        case .open:
            return openRows.first { $0.id == selectedOpenID }?.reference
        case .history:
            return historyRows.first { $0.id == selectedHistoryID }?.reference
        }
    }
}
