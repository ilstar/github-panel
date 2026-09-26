import Foundation

protocol GitHubAPIClient {
    func fetchCurrentUser(token: String) async throws -> GitHubUser
    func fetchOpenPRs(token: String) async throws -> OpenPullRequests
    func fetchClosedPRs(token: String, username: String, page: Int, perPage: Int) async throws -> PullRequestHistoryPage
    func fetchReviewRequests(token: String) async throws -> ReviewRequests
    func enqueuePullRequest(token: String, pullRequestID: String) async throws
    func markPullRequestReadyForReview(token: String, pullRequestID: String) async throws
    func enableAutoMerge(token: String, pullRequestID: String) async throws
    func disableAutoMerge(token: String, pullRequestID: String) async throws
    func mergePullRequest(token: String, repoFullName: String, number: Int) async throws -> Bool
    func fetchPullRequestDetail(token: String, reference: PullRequestReference) async throws -> PullRequestDetailContent
    func setFileViewed(token: String, pullRequestID: String, path: String, viewed: Bool) async throws
    func fetchPullRequestComments(token: String, reference: PullRequestReference) async throws -> PullRequestComments
    func postPullRequestComment(token: String, reference: PullRequestReference, comment: NewPullRequestComment) async throws
}

protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

struct GitHubUser: Decodable {
    let login: String
}

struct OpenPullRequests {
    let login: String
    let rows: [PullRequestRow]
}
