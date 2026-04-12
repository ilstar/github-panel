import Foundation

struct GitHubUser: Decodable {
    let login: String
}

struct PullRequestInfo: Identifiable {
    let id = UUID()
    let nodeID: String
    let title: String
    let number: Int
    let repoFullName: String
    let htmlURL: URL
    let headSHA: String
    let isDraft: Bool
    let status: CheckState
    let isAutoMergeEnabled: Bool
    let canEnableAutoMerge: Bool
    let canDisableAutoMerge: Bool
    let isMergeQueueEnabled: Bool
    let isInMergeQueue: Bool
    let mergeStateStatus: String
}

struct PullRequestSummary: Identifiable {
    let id: String
    let title: String
    let number: Int
    let repoFullName: String
    let htmlURL: URL
    let updatedAt: Date
}

struct PullRequestRow: Identifiable {
    let id: String
    let nodeID: String
    let title: String
    let number: Int
    let repoFullName: String
    let htmlURL: URL
    let status: CheckState
    let isDraft: Bool
    let isAutoMergeEnabled: Bool
    let canEnableAutoMerge: Bool
    let canDisableAutoMerge: Bool
    let isMergeQueueEnabled: Bool
    let isInMergeQueue: Bool
    let mergeStateStatus: String
    let updatedAt: Date
}

enum CheckState: String {
    case success
    case failure
    case error
    case pending
    case unknown

    init(githubStatus: String?) {
        switch githubStatus {
        case "SUCCESS", nil:
            self = .success
        case "FAILURE":
            self = .failure
        case "ERROR":
            self = .error
        case "PENDING", "EXPECTED":
            self = .pending
        default:
            self = .unknown
        }
    }

    var emoji: String {
        switch self {
        case .success: return "✅"
        case .failure, .error: return "❌"
        case .pending: return "⏳"
        case .unknown: return "❔"
        }
    }

    var descriptionText: String {
        switch self {
        case .success: return "All checks are done."
        case .failure, .error: return "Checks failed."
        case .pending: return "Still building."
        case .unknown: return "Status unavailable."
        }
    }
}

final class GitHubAPI {
    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        let request = makeRequest(path: "/user", token: token)
        return try await decode(GitHubUser.self, request: request)
    }

    func fetchOpenPRs(token: String, username: String) async throws -> [PullRequestSummary] {
        let query = "is:pr author:\(username) is:open sort:updated-desc"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let request = makeRequest(path: "/search/issues?q=\(encoded)", token: token)
        let response = try await decode(SearchResponse.self, request: request)
        return response.items.compactMap { item in
            let components = item.repositoryURL.pathComponents
            guard components.count >= 4 else { return nil }
            let repoFullName = "\(components[2])/\(components[3])"
            return PullRequestSummary(id: "\(repoFullName)#\(item.number)",
                                      title: item.title,
                                      number: item.number,
                                      repoFullName: repoFullName,
                                      htmlURL: item.htmlURL,
                                      updatedAt: item.updatedAt)
        }
    }

    func fetchPullRequest(token: String, repoFullName: String, number: Int) async throws -> PullRequestInfo {
        let parts = repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw URLError(.badURL) }

        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              id
              title
              number
              url
              headRefOid
              isDraft
              autoMergeRequest { enabledAt }
              viewerCanEnableAutoMerge
              viewerCanDisableAutoMerge
              isMergeQueueEnabled
              isInMergeQueue
              mergeStateStatus
              statusCheckRollup { state }
            }
          }
        }
        """

        let response = try await graphQL(PullRequestDetailResponse.self,
                                         query: query,
                                         variables: ["owner": parts[0], "name": parts[1], "number": number],
                                         token: token)
        guard let pr = response.repository?.pullRequest else {
            throw GraphQLError(message: "Pull request not found.")
        }

        return PullRequestInfo(nodeID: pr.id,
                               title: pr.title,
                               number: pr.number,
                               repoFullName: repoFullName,
                               htmlURL: pr.url,
                               headSHA: pr.headRefOid,
                               isDraft: pr.isDraft,
                               status: CheckState(githubStatus: pr.statusCheckRollup?.state),
                               isAutoMergeEnabled: pr.autoMergeRequest != nil,
                               canEnableAutoMerge: pr.viewerCanEnableAutoMerge,
                               canDisableAutoMerge: pr.viewerCanDisableAutoMerge,
                               isMergeQueueEnabled: pr.isMergeQueueEnabled,
                               isInMergeQueue: pr.isInMergeQueue,
                               mergeStateStatus: pr.mergeStateStatus)
    }

    func fetchPRCheckState(token: String, pr: PullRequestInfo) async throws -> CheckState {
        let path = "/repos/\(pr.repoFullName)/commits/\(pr.headSHA)/status"
        let request = makeRequest(path: path, token: token)
        let response = try await decode(StatusResponse.self, request: request)
        if response.totalCount == 0 {
            return .success
        }
        return CheckState(rawValue: response.state) ?? .unknown
    }

    func enqueuePullRequest(token: String, pullRequestID: String) async throws {
        let query = """
        mutation($id: ID!) {
          enqueuePullRequest(input: { pullRequestId: $id }) {
            mergeQueueEntry { id }
          }
        }
        """
        struct Response: Decodable { let enqueuePullRequest: EnqueueResult? }
        struct EnqueueResult: Decodable { let mergeQueueEntry: MergeQueueEntry }
        struct MergeQueueEntry: Decodable { let id: String }
        _ = try await graphQL(Response.self, query: query, variables: ["id": pullRequestID], token: token)
    }

    func enableAutoMerge(token: String, pullRequestID: String) async throws {
        let query = """
        mutation($id: ID!) {
          enablePullRequestAutoMerge(input: { pullRequestId: $id, mergeMethod: MERGE }) {
            pullRequest { id }
          }
        }
        """
        struct Response: Decodable { let enablePullRequestAutoMerge: EnableResult? }
        struct EnableResult: Decodable { let pullRequest: PullRequestNode }
        struct PullRequestNode: Decodable { let id: String }
        _ = try await graphQL(Response.self, query: query, variables: ["id": pullRequestID], token: token)
    }

    func disableAutoMerge(token: String, pullRequestID: String) async throws {
        let query = """
        mutation($id: ID!) {
          disablePullRequestAutoMerge(input: { pullRequestId: $id }) {
            pullRequest { id }
          }
        }
        """
        struct Response: Decodable { let disablePullRequestAutoMerge: DisableResult? }
        struct DisableResult: Decodable { let pullRequest: PullRequestNode }
        struct PullRequestNode: Decodable { let id: String }
        _ = try await graphQL(Response.self, query: query, variables: ["id": pullRequestID], token: token)
    }

    func mergePullRequest(token: String, repoFullName: String, number: Int) async throws -> Bool {
        let parts = repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw URLError(.badURL) }
        var request = makeRequest(path: "/repos/\(parts[0])/\(parts[1])/pulls/\(number)/merge", token: token)
        request.httpMethod = "PUT"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["merge_method": "merge"])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
            throw GitHubAPIError(message: raw, documentationURL: nil, statusCode: http.statusCode)
        }
        struct MergeResponse: Decodable { let merged: Bool }
        if let decoded = try? JSONDecoder().decode(MergeResponse.self, from: data) {
            return decoded.merged
        }
        return true
    }

    private func makeRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("GithubPanel", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(GitHubAPIError.self, from: data) {
                throw apiError.withStatus(http.statusCode)
            }
            throw GitHubAPIError(message: "Unexpected response from GitHub.", documentationURL: nil, statusCode: http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private func graphQL<T: Decodable>(_ type: T.Type,
                                       query: String,
                                       variables: [String: Any],
                                       token: String) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("GithubPanel", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
            throw GraphQLError(message: "GraphQL HTTP \(http.statusCode): \(raw)")
        }
        let decoder = JSONDecoder()
        let envelope: GraphQLResponse<T>
        do {
            envelope = try decoder.decode(GraphQLResponse<T>.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
            throw GraphQLError(message: "GraphQL decode failed: \(raw)")
        }
        if let errors = envelope.errors, !errors.isEmpty {
            throw GraphQLError(message: errors.map(\.message).joined(separator: " "))
        }
        guard let value = envelope.data else {
            throw GraphQLError(message: "Empty response from GitHub.")
        }
        return value
    }
}

struct GitHubAPIError: Decodable, LocalizedError {
    let message: String
    let documentationURL: URL?
    var statusCode: Int?

    enum CodingKeys: String, CodingKey {
        case message
        case documentationURL = "documentation_url"
    }

    func withStatus(_ status: Int) -> GitHubAPIError {
        var copy = self
        copy.statusCode = status
        return copy
    }

    var errorDescription: String? {
        if let statusCode {
            return "GitHub API error (\(statusCode)): \(message)"
        }
        return "GitHub API error: \(message)"
    }
}

private struct SearchResponse: Decodable {
    let items: [SearchItem]
}

private struct SearchItem: Decodable {
    let number: Int
    let repositoryURL: URL
    let title: String
    let htmlURL: URL
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case number
        case repositoryURL = "repository_url"
        case title
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
    }
}

private struct PullRequestDetailResponse: Decodable {
    let repository: PullRequestRepository?
}

private struct PullRequestRepository: Decodable {
    let pullRequest: PullRequestNode?
}

private struct PullRequestNode: Decodable {
    let id: String
    let title: String
    let number: Int
    let url: URL
    let headRefOid: String
    let isDraft: Bool
    let autoMergeRequest: AutoMergeRequest?
    let viewerCanEnableAutoMerge: Bool
    let viewerCanDisableAutoMerge: Bool
    let isMergeQueueEnabled: Bool
    let isInMergeQueue: Bool
    let mergeStateStatus: String
    let statusCheckRollup: StatusCheckRollup?
}

private struct StatusCheckRollup: Decodable {
    let state: String
}

private struct PullResponse: Decodable {
    let nodeID: String
    let title: String
    let number: Int
    let htmlURL: URL
    let head: PullHead
    let draft: Bool
    let autoMerge: AutoMergeRequest?

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case title
        case number
        case htmlURL = "html_url"
        case head
        case draft
        case autoMerge = "auto_merge"
    }
}

private struct AutoMergeRequest: Decodable {}

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLErrorPayload]?
}

private struct GraphQLErrorPayload: Decodable {
    let message: String
}

struct GraphQLError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct PullHead: Decodable {
    let sha: String
}

private struct StatusResponse: Decodable {
    let state: String
    let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case state
        case totalCount = "total_count"
    }
}
