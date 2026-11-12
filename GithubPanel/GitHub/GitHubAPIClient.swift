import Foundation

protocol GitHubAPIClient {
    func fetchCurrentUser(token: String) async throws -> GitHubUser
    func fetchOpenPRs(token: String) async throws -> OpenPullRequests
    func fetchOpenPRPage(token: String, request: PullRequestPageRequest) async throws -> OpenPullRequests
    func fetchClosedPRs(token: String, username: String, page: Int, perPage: Int) async throws -> PullRequestHistoryPage
    func fetchReviewRequests(token: String) async throws -> ReviewRequests
    func fetchReviewRequestPage(token: String, request: PullRequestPageRequest,
                                hidden: [String: HiddenReviewRequest]) async throws -> ReviewRequests
    func enqueuePullRequest(token: String, pullRequestID: String) async throws
    func markPullRequestReadyForReview(token: String, pullRequestID: String) async throws
    func enableAutoMerge(token: String, pullRequestID: String, mergeMethod: MergeMethod) async throws
    func disableAutoMerge(token: String, pullRequestID: String) async throws
    func mergePullRequest(token: String, repoFullName: String, number: Int, method: MergeMethod) async throws -> Bool
    func fetchPullRequestDetail(token: String, reference: PullRequestReference) async throws -> PullRequestDetailContent
    /// The files that changed between two commits, such as the one the viewer last reviewed and the head commit.
    func fetchChangedFiles(token: String, repoFullName: String, baseSHA: String, headSHA: String) async throws -> [PullRequestFile]
    func setFileViewed(token: String, pullRequestID: String, path: String, viewed: Bool) async throws
    /// The pull request's newest general comments and first review threads, up to `limits`.
    func fetchPullRequestComments(token: String, reference: PullRequestReference,
                                  limits: PullRequestCommentLimits) async throws -> PullRequestComments
    /// Posts a comment and returns its REST ID.
    @discardableResult
    func postPullRequestComment(token: String, reference: PullRequestReference, comment: NewPullRequestComment) async throws -> Int
    func setReviewThreadResolved(token: String, threadID: String, resolved: Bool) async throws
    func editPullRequest(token: String, reference: PullRequestReference, title: String?, body: String?) async throws
    /// Submits a review and returns its REST ID.
    @discardableResult
    func submitReview(token: String, reference: PullRequestReference, review: NewPullRequestReview) async throws -> Int
    /// Starts a pending review on the given commit and returns its node ID.
    func startPendingReview(token: String, pullRequestID: String, commitID: String) async throws -> String
    /// Adds a draft comment to a pending review and returns its REST ID, when GitHub sends it.
    @discardableResult
    func addPendingReviewComment(token: String, reviewID: String, comment: PendingReviewComment) async throws -> Int?
    /// Submits a pending review and returns its REST ID, when GitHub sends it.
    @discardableResult
    func submitPendingReview(token: String, reviewID: String, event: PullRequestReviewEvent, body: String) async throws -> Int?
    func deletePendingReview(token: String, reviewID: String) async throws
    func updatePullRequestBranch(token: String, pullRequestID: String, expectedHeadSHA: String) async throws
    /// The check runs and commit statuses on the pull request's head commit.
    func fetchPullRequestChecks(token: String, reference: PullRequestReference) async throws -> PullRequestChecks
    /// Runs a workflow run's failed jobs, or another app's check suite, again.
    func rerunChecks(token: String, repoFullName: String, rerun: CheckRerun) async throws
    /// Users and teams that could review the pull request, matching `query`, for the reviewer picker.
    func fetchReviewerCandidates(token: String, reference: PullRequestReference, query: String) async throws -> [ReviewerCandidate]
    /// GitHub users whose login or name matches `query`, for an @mention in a comment on the pull request.
    /// People with access to its repository come first; an empty query lists only them.
    func searchMentionCandidates(token: String, reference: PullRequestReference, query: String) async throws -> [MentionCandidate]
    /// Requests a review from a user or team (`org/team-slug`), or removes their request.
    func setReviewRequested(token: String, reference: PullRequestReference, name: String,
                            kind: PullRequestReviewer.Kind, requested: Bool) async throws
}

extension GitHubAPIClient {
    /// The comments a pull request shows first.
    func fetchPullRequestComments(token: String, reference: PullRequestReference) async throws -> PullRequestComments {
        try await fetchPullRequestComments(token: token, reference: reference, limits: PullRequestCommentLimits())
    }
}

protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

struct GitHubUser: Decodable {
    let login: String
}

/// A cursor is the boundary before a page, rather than an offset into a changing list.
struct PullRequestPageRequest: Hashable, Codable {
    var page = 1
    var after: String?
    var teamAfter: String?
    var directFinished = false
    var directLoaded = 0
    var teamLoaded = 0
}

struct PullRequestPagination: Equatable, Codable {
    var request: PullRequestPageRequest
    var next: PullRequestPageRequest?
    var totalCount: Int
    var fromMeTotal: Int? = nil
    var fromMyTeamsTotal: Int? = nil
    /// Only hidden requests verified to still match their saved fingerprint.
    var hidden: [String: HiddenReviewRequest]? = nil
}

struct OpenPullRequests {
    let login: String
    let rows: [PullRequestRow]
    /// Set when some pull requests were left out because the token isn't SSO-authorized for their organization.
    var ssoAuthorizationURL: URL? = nil
    var pagination: PullRequestPagination? = nil
}

/// In-memory providers can keep supplying complete fixtures; network providers override these operations.
extension GitHubAPIClient {
    func fetchOpenPRPage(token: String, request: PullRequestPageRequest) async throws -> OpenPullRequests {
        try await fetchOpenPRs(token: token).page(request)
    }

    func fetchReviewRequestPage(token: String, request: PullRequestPageRequest,
                                hidden: [String: HiddenReviewRequest]) async throws -> ReviewRequests {
        try await fetchReviewRequests(token: token).page(request, hidden: hidden)
    }
}

extension OpenPullRequests {
    func page(_ request: PullRequestPageRequest) -> OpenPullRequests {
        let total = rows.count
        let page = min(max(1, request.page), max(1, (total + 49) / 50))
        return OpenPullRequests(login: login, rows: Array(rows.dropFirst((page - 1) * 50).prefix(50)),
                                ssoAuthorizationURL: ssoAuthorizationURL,
                                pagination: .init(request: .init(page: page),
                                                  next: page * 50 < total ? .init(page: page + 1) : nil,
                                                  totalCount: total))
    }
}

extension ReviewRequests {
    func page(_ request: PullRequestPageRequest, hidden: [String: HiddenReviewRequest]) -> ReviewRequests {
        let retained = hidden.filter { id, fingerprint in rows.first { $0.id == id }.map(fingerprint.hides) ?? false }
        let visible = removing { retained[$0.id] != nil }
        let page = ReviewRequestsPage(requests: visible, page: request.page)
        return ReviewRequests(fromMe: page.fromMe, fromMyTeams: page.fromMyTeams,
                              ssoAuthorizationURL: ssoAuthorizationURL,
                              pagination: .init(request: .init(page: page.page),
                                                next: page.canGoToNextPage ? .init(page: page.page + 1) : nil,
                                                totalCount: page.totalCount, fromMeTotal: page.fromMeTotal,
                                                fromMyTeamsTotal: page.fromMyTeamsTotal, hidden: retained))
    }
}
