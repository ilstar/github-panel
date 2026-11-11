import Foundation

/// A pull request's head commit and the state of its checks, as last seen by any load: a list, the detail, or
/// the checks. Rows show this instead of what their own list returned, so one pull request never shows two states.
struct PullRequestStatus: Equatable, Codable {
    var headSHA: String
    /// Nil while nothing has reported the checks on this head, such as right after a push. Rows show it as pending.
    var checkState: CheckState?
    /// When the request that saw this was sent. GitHub may have changed after that, so a later request wins.
    var observedAt: Date

    /// The newer of the two. When the newer one says nothing about the checks on the same head, the older one's
    /// state still holds; on a different head, the checks aren't known yet.
    func merging(_ other: PullRequestStatus) -> PullRequestStatus {
        let (newer, older) = other.observedAt >= observedAt ? (other, self) : (self, other)
        var merged = newer
        if merged.checkState == nil, older.headSHA == newer.headSHA {
            merged.checkState = older.checkState
        }
        return merged
    }
}

/// A pull request's detail as last loaded, with what loaded alongside it.
struct PullRequestDetailEntry: Equatable, Codable {
    var content: PullRequestDetailContent
    /// Nil until the comments first load.
    var comments: PullRequestComments?
    var commentLimits = PullRequestCommentLimits()
    var checks: PullRequestChecks?
    var filesSinceLastReview: [PullRequestFile]?
}

/// The list columns of a SQLite PR row. Detail blobs are read separately for open detail views.
struct PullRequestRecord: Equatable {
    var openRow: PullRequestRow?
    var reviewRequestRow: ReviewRequestRow?
    var historyRow: PullRequestHistoryRow?
    var status: PullRequestStatus?

    mutating func observe(_ status: PullRequestStatus) {
        self.status = self.status.map { $0.merging(status) } ?? status
    }

    /// My PRs' row, showing the newest status.
    var shownOpenRow: PullRequestRow? {
        guard var row = openRow else { return nil }
        if let status {
            row.headSHA = status.headSHA
            row.status = status.checkState ?? .pending
        }
        return row
    }

    /// To Review's row, showing the newest status. GitHub reporting no checks is `nil` there.
    var shownReviewRequestRow: ReviewRequestRow? {
        guard var row = reviewRequestRow else { return nil }
        if let status {
            row.headSHA = status.headSHA
            let state = status.checkState ?? .pending
            row.checkState = state == .noChecks ? nil : state
        }
        return row
    }
}

/// A pull request's place in a list.
struct PullRequestListMember: Equatable {
    let reference: PullRequestReference
    /// Which To Review group it's in. Nil in other lists.
    var reviewGroup: ReviewRequestGroup?
}

/// The rows each list shows, from its members and their records. The cache and the store's saved lists both build
/// their rows here, so the lists on screen match what a restart would show.
enum PullRequestListRows {
    static func open(_ members: [PullRequestListMember]?,
                     records: [PullRequestReference: PullRequestRecord]) -> [PullRequestRow]? {
        members?.compactMap { records[$0.reference]?.shownOpenRow }
    }

    static func reviewRequests(_ members: [PullRequestListMember]?, info: PullRequestListInfo?,
                               records: [PullRequestReference: PullRequestRecord]) -> ReviewRequests? {
        guard let members else { return nil }
        func rows(in group: ReviewRequestGroup) -> [ReviewRequestRow] {
            members.filter { $0.reviewGroup == group }.compactMap { records[$0.reference]?.shownReviewRequestRow }
        }
        return ReviewRequests(fromMe: rows(in: .fromMe), fromMyTeams: rows(in: .fromMyTeams),
                              ssoAuthorizationURL: info?.ssoAuthorizationURL)
    }

    static func historyPage(_ page: Int, members: [PullRequestListMember]?, info: PullRequestListInfo?,
                            records: [PullRequestReference: PullRequestRecord]) -> PullRequestHistoryPage? {
        guard let members, let info, let perPage = info.perPage, let totalCount = info.totalCount else { return nil }
        return PullRequestHistoryPage(rows: members.compactMap { records[$0.reference]?.historyRow },
                                      page: info.page ?? page, perPage: perPage, totalCount: totalCount)
    }
}

/// What a list holds besides its pull requests.
struct PullRequestListInfo: Equatable, Codable {
    var ssoAuthorizationURL: URL?
    /// For History pages.
    var page: Int?
    var perPage: Int?
    var totalCount: Int?
}

extension PullRequestRow {
    func status(observedAt: Date) -> PullRequestStatus {
        PullRequestStatus(headSHA: headSHA, checkState: status, observedAt: observedAt)
    }
}

extension ReviewRequestRow {
    /// Nil when GitHub didn't return the head commit.
    func status(observedAt: Date) -> PullRequestStatus? {
        headSHA.map { PullRequestStatus(headSHA: $0, checkState: checkState ?? .noChecks, observedAt: observedAt) }
    }
}

extension PullRequestChecks {
    /// The state the checks add up to, like GitHub's rollup. Nil when none reported, since GitHub may still expect
    /// some, which only its rollup knows, and when the load may have left some out.
    var checkState: CheckState? {
        guard !checks.isEmpty, checks.count < Self.loadLimit else { return nil }
        if checks.contains(where: { $0.outcome == .failure }) { return .failure }
        if checks.contains(where: { $0.outcome == .pending }) { return .pending }
        return .success
    }

    /// How many checks `fetchPullRequestChecks` loads at most.
    static let loadLimit = 100
}
