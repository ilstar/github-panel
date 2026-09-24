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
