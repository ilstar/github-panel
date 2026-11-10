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

/// Everything the lists know about one pull request: the row each list's query returned, and its status.
/// Saved as one `pull_request` row, which also holds the detail.
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
