import Foundation

/// Open pull requests waiting on the viewer's review, split by who the review was requested from.
struct ReviewRequests: Equatable {
    /// Review requested from the viewer directly.
    let fromMe: [ReviewRequestRow]
    /// Review requested only from a team the viewer belongs to.
    let fromMyTeams: [ReviewRequestRow]

    static let empty = ReviewRequests(fromMe: [], fromMyTeams: [])

    /// GitHub's `review-requested:@me` matches both direct and team requests, while
    /// `user-review-requested:@me` matches only direct ones; team requests are the difference.
    init(direct: [ReviewRequestRow], all: [ReviewRequestRow]) {
        let directIDs = Set(direct.map(\.id))
        self.init(fromMe: direct, fromMyTeams: all.filter { !directIDs.contains($0.id) })
    }

    init(fromMe: [ReviewRequestRow], fromMyTeams: [ReviewRequestRow]) {
        self.fromMe = fromMe
        self.fromMyTeams = fromMyTeams
    }

    /// Rows in display order: requests from me first, then from my teams.
    var rows: [ReviewRequestRow] {
        fromMe + fromMyTeams
    }

    func rows(in group: ReviewRequestGroup) -> [ReviewRequestRow] {
        switch group {
        case .fromMe: return fromMe
        case .fromMyTeams: return fromMyTeams
        }
    }
}

enum ReviewRequestGroup: CaseIterable, Identifiable {
    case fromMe
    case fromMyTeams

    var id: Self { self }

    var title: String {
        switch self {
        case .fromMe: return "Requested from me"
        case .fromMyTeams: return "Requested from my teams"
        }
    }

    var emptyText: String {
        switch self {
        case .fromMe: return "Nothing requested from you directly."
        case .fromMyTeams: return "Nothing requested from your teams."
        }
    }
}

struct ReviewRequestRow: Identifiable, Equatable {
    let id: String
    let title: String
    let number: Int
    let repoFullName: String
    let htmlURL: URL
    let authorLogin: String?
    let isDraft: Bool
    let updatedAt: Date

    var reference: PullRequestReference {
        PullRequestReference(repoFullName: repoFullName, number: number)
    }
}

/// What the To Review tab shows in place of, or alongside, its rows.
enum ReviewRequestsDisplayState: Equatable {
    case loading
    case failed(String)
    case empty
    case list

    init(requests: ReviewRequests, isLoading: Bool, error: String?, hasLoaded: Bool) {
        if !requests.rows.isEmpty {
            self = .list
        } else if let error {
            self = .failed(error)
        } else if isLoading || !hasLoaded {
            self = .loading
        } else {
            self = .empty
        }
    }
}
