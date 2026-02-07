import Foundation

struct GitHubUser: Decodable {
    let login: String
}

struct PullRequestInfo: Identifiable {
    let id = UUID()
    let title: String
    let number: Int
    let repoFullName: String
    let htmlURL: URL
    let headSHA: String
}

enum CheckState: String {
    case success
    case failure
    case error
    case pending
    case unknown

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

    func fetchLatestOpenPR(token: String, username: String) async throws -> PullRequestInfo? {
        let query = "is:pr author:\(username) is:open sort:updated-desc"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let request = makeRequest(path: "/search/issues?q=\(encoded)", token: token)
        let response = try await decode(SearchResponse.self, request: request)
        guard let item = response.items.first else { return nil }
        let components = item.repositoryURL.pathComponents
        guard components.count >= 4 else { return nil }
        let repoFullName = "\(components[2])/\(components[3])"

        let prRequest = makeRequest(path: "/repos/\(repoFullName)/pulls/\(item.number)", token: token)
        let pr = try await decode(PullResponse.self, request: prRequest)
        return PullRequestInfo(title: pr.title,
                               number: pr.number,
                               repoFullName: repoFullName,
                               htmlURL: pr.htmlURL,
                               headSHA: pr.head.sha)
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
        return try JSONDecoder().decode(T.self, from: data)
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

    enum CodingKeys: String, CodingKey {
        case number
        case repositoryURL = "repository_url"
    }
}

private struct PullResponse: Decodable {
    let title: String
    let number: Int
    let htmlURL: URL
    let head: PullHead

    enum CodingKeys: String, CodingKey {
        case title
        case number
        case htmlURL = "html_url"
        case head
    }
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
