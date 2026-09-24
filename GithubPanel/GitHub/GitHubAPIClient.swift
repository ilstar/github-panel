import Foundation

protocol GitHubAPIClient {
    func fetchCurrentUser(token: String) async throws -> GitHubUser
    func fetchOpenPRs(token: String) async throws -> OpenPullRequests
    func fetchClosedPRs(token: String, username: String, page: Int, perPage: Int) async throws -> PullRequestHistoryPage
    func enqueuePullRequest(token: String, pullRequestID: String) async throws
    func markPullRequestReadyForReview(token: String, pullRequestID: String) async throws
    func enableAutoMerge(token: String, pullRequestID: String) async throws
    func disableAutoMerge(token: String, pullRequestID: String) async throws
    func mergePullRequest(token: String, repoFullName: String, number: Int) async throws -> Bool
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
