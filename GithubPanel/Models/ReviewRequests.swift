import Foundation

/// Open pull requests waiting on the viewer's review, split by who the review was requested from.
struct ReviewRequests: Equatable {
    /// Review requested from the viewer directly.
    let fromMe: [ReviewRequestRow]
    /// Review requested only from a team the viewer belongs to.
    let fromMyTeams: [ReviewRequestRow]
    /// Set when some requests were left out because the token isn't SSO-authorized for their organization.
    let ssoAuthorizationURL: URL?

    static let empty = ReviewRequests(fromMe: [], fromMyTeams: [])

    /// GitHub's `review-requested:@me` matches both direct and team requests, while
    /// `user-review-requested:@me` matches only direct ones; team requests are the difference.
    init(direct: [ReviewRequestRow], all: [ReviewRequestRow], ssoAuthorizationURL: URL? = nil) {
        let directIDs = Set(direct.map(\.id))
        self.init(fromMe: direct, fromMyTeams: all.filter { !directIDs.contains($0.id) },
                  ssoAuthorizationURL: ssoAuthorizationURL)
    }

    init(fromMe: [ReviewRequestRow], fromMyTeams: [ReviewRequestRow], ssoAuthorizationURL: URL? = nil) {
        self.fromMe = fromMe
        self.fromMyTeams = fromMyTeams
        self.ssoAuthorizationURL = ssoAuthorizationURL
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

    /// The requests without the rows `isHidden` picks.
    func removing(where isHidden: (ReviewRequestRow) -> Bool) -> ReviewRequests {
        ReviewRequests(fromMe: fromMe.filter { !isHidden($0) },
                       fromMyTeams: fromMyTeams.filter { !isHidden($0) },
                       ssoAuthorizationURL: ssoAuthorizationURL)
    }
}

/// What a review request looked like when it was hidden. It stays hidden until new commits are pushed
/// or my review is requested again.
struct HiddenReviewRequest: Codable, Equatable {
    let headSHA: String?
    let requestedAt: Date?

    init(_ row: ReviewRequestRow) {
        headSHA = row.headSHA
        requestedAt = row.requestedAt
    }

    func hides(_ row: ReviewRequestRow) -> Bool {
        headSHA == row.headSHA && requestedAt == row.requestedAt
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
    /// Nil when GitHub reports no check status for the head commit.
    var checkState: CheckState?
    var additions: Int?
    var deletions: Int?
    /// When my review, or my team's, was last requested. Nil when GitHub does not say.
    var requestedAt: Date?
    /// The head commit, so a hidden request shows again after a push.
    var headSHA: String?

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

/// One page of the To Review list. Pages run through the requests from me, then from my teams,
/// so a page may hold the end of one group and the start of the next.
struct ReviewRequestsPage: Equatable {
    static let defaultSize = 10

    /// 1-based, and always within `1...pageCount`.
    let page: Int
    let pageCount: Int
    let totalCount: Int
    let fromMe: [ReviewRequestRow]
    let fromMyTeams: [ReviewRequestRow]
    private let start: Int

    /// `page` is clamped, so a page past the end shows the last one after rows go away.
    init(requests: ReviewRequests, page: Int, size: Int = ReviewRequestsPage.defaultSize) {
        let size = max(size, 1)
        totalCount = requests.rows.count
        pageCount = max(1, (totalCount + size - 1) / size)
        self.page = min(max(page, 1), pageCount)
        start = (self.page - 1) * size
        let end = min(start + size, totalCount)
        let fromMeCount = requests.fromMe.count
        fromMe = Array(requests.fromMe[min(start, fromMeCount)..<min(end, fromMeCount)])
        fromMyTeams = Array(requests.fromMyTeams[max(start - fromMeCount, 0)..<max(end - fromMeCount, 0)])
    }

    /// The page that shows the request with `id`, or nil when it is not in `requests`.
    static func page(containing id: String, in requests: ReviewRequests,
                     size: Int = ReviewRequestsPage.defaultSize) -> Int? {
        requests.rows.firstIndex { $0.id == id }.map { $0 / max(size, 1) + 1 }
    }

    /// Rows on this page in display order.
    var rows: [ReviewRequestRow] {
        fromMe + fromMyTeams
    }

    func rows(in group: ReviewRequestGroup) -> [ReviewRequestRow] {
        switch group {
        case .fromMe: return fromMe
        case .fromMyTeams: return fromMyTeams
        }
    }

    /// A group's heading shows on the pages that hold its rows. An empty group shows where it would
    /// start: requests from me on the first page, requests from my teams on the last.
    func showsGroup(_ group: ReviewRequestGroup, in requests: ReviewRequests) -> Bool {
        if !rows(in: group).isEmpty { return true }
        guard requests.rows(in: group).isEmpty else { return false }
        switch group {
        case .fromMe: return page == 1
        case .fromMyTeams: return page == pageCount
        }
    }

    var hasMultiplePages: Bool { pageCount > 1 }
    var canGoToPreviousPage: Bool { page > 1 }
    var canGoToNextPage: Bool { page < pageCount }

    var rangeText: String {
        guard totalCount > 0 else { return "No review requests" }
        return "\(start + 1)-\(start + rows.count) of \(totalCount)"
    }
}
