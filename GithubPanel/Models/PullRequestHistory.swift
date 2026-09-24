import Foundation

struct PullRequestHistoryPage {
    let rows: [PullRequestHistoryRow]
    let page: Int
    let perPage: Int
    let totalCount: Int

    var hasPreviousPage: Bool {
        page > 1
    }

    var hasNextPage: Bool {
        page * perPage < totalCount
    }
}

struct PullRequestHistoryRow: Identifiable, Equatable {
    let id: String
    let title: String
    let number: Int
    let repoFullName: String
    let htmlURL: URL
    let updatedAt: Date
    let closedAt: Date?
    let mergedAt: Date?

    var outcome: PullRequestHistoryOutcome {
        mergedAt == nil ? .closed : .merged
    }
}

enum PullRequestHistoryOutcome: Equatable {
    case merged
    case closed

    var title: String {
        switch self {
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    var iconName: String {
        switch self {
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle.fill"
        }
    }
}
