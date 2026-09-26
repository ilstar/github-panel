import Foundation
final class GitHubAPI: GitHubAPIClient {
    private let transport: HTTPTransport

    init(transport: HTTPTransport = URLSession.shared) {
        self.transport = transport
    }

    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        let request = makeRequest(path: "/user", token: token)
        return try await decode(GitHubUser.self, request: request)
    }

    func fetchOpenPRs(token: String) async throws -> OpenPullRequests {
        let query = """
        query {
          viewer {
            login
            pullRequests(first: 10, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                id
                title
                number
                url
                updatedAt
                repository { nameWithOwner }
                headRefOid
                isDraft
                autoMergeRequest { enabledAt }
                viewerCanEnableAutoMerge
                viewerCanDisableAutoMerge
                isMergeQueueEnabled
                isInMergeQueue
                mergeStateStatus
                statusCheckRollup {
                  state
                  contexts(first: 1) { totalCount }
                }
              }
            }
          }
        }
        """
        let response = try await graphQL(OpenPullRequestsResponse.self,
                                         query: query, variables: [:], token: token)
        let rows = response.viewer.pullRequests.nodes.map { pr in
            PullRequestRow(id: "\(pr.repository.nameWithOwner)#\(pr.number)",
                           nodeID: pr.id,
                           title: pr.title,
                           number: pr.number,
                           repoFullName: pr.repository.nameWithOwner,
                           htmlURL: pr.url,
                           headSHA: pr.headRefOid,
                           status: CheckState(githubStatus: pr.statusCheckRollup?.state,
                                              hasCheckContexts: pr.statusCheckRollup?.contexts.map { $0.totalCount > 0 }),
                           isDraft: pr.isDraft,
                           isAutoMergeEnabled: pr.autoMergeRequest != nil,
                           canEnableAutoMerge: pr.viewerCanEnableAutoMerge,
                           canDisableAutoMerge: pr.viewerCanDisableAutoMerge,
                           isMergeQueueEnabled: pr.isMergeQueueEnabled,
                           isInMergeQueue: pr.isInMergeQueue,
                           mergeStateStatus: pr.mergeStateStatus,
                           updatedAt: pr.updatedAt)
        }
        return OpenPullRequests(login: response.viewer.login, rows: rows)
    }

    func fetchClosedPRs(token: String, username: String, page: Int, perPage: Int) async throws -> PullRequestHistoryPage {
        let query = "is:pr author:\(username) is:closed sort:updated-desc"
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let safePage = max(1, page)
        let safePerPage = max(1, min(perPage, 100))
        let request = makeRequest(path: "/search/issues?q=\(encoded)&page=\(safePage)&per_page=\(safePerPage)", token: token)
        let response = try await decode(SearchResponse.self, request: request)
        let rows = response.items.compactMap { item -> PullRequestHistoryRow? in
            guard let repoFullName = repoFullName(from: item) else { return nil }
            return PullRequestHistoryRow(id: "\(repoFullName)#\(item.number)",
                                         title: item.title,
                                         number: item.number,
                                         repoFullName: repoFullName,
                                         htmlURL: item.htmlURL,
                                         updatedAt: item.updatedAt,
                                         closedAt: item.closedAt,
                                         mergedAt: item.pullRequest?.mergedAt)
        }
        return PullRequestHistoryPage(rows: rows,
                                      page: safePage,
                                      perPage: safePerPage,
                                      totalCount: response.totalCount)
    }

    func fetchReviewRequests(token: String) async throws -> ReviewRequests {
        let query = """
        query {
          direct: search(query: "is:pr is:open archived:false user-review-requested:@me sort:updated-desc", type: ISSUE, first: 50) {
            nodes { ...ReviewRequestFields }
          }
          all: search(query: "is:pr is:open archived:false review-requested:@me sort:updated-desc", type: ISSUE, first: 50) {
            nodes { ...ReviewRequestFields }
          }
        }

        fragment ReviewRequestFields on PullRequest {
          id
          title
          number
          url
          updatedAt
          isDraft
          repository { nameWithOwner }
          author { login }
        }
        """
        let response = try await graphQL(ReviewRequestsResponse.self,
                                         query: query, variables: [:], token: token)
        return ReviewRequests(direct: response.direct.rows, all: response.all.rows)
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

    func markPullRequestReadyForReview(token: String, pullRequestID: String) async throws {
        let query = """
        mutation($id: ID!) {
          markPullRequestReadyForReview(input: { pullRequestId: $id }) {
            pullRequest { id }
          }
        }
        """
        struct Response: Decodable { let markPullRequestReadyForReview: ReadyResult? }
        struct ReadyResult: Decodable { let pullRequest: PullRequestNode }
        struct PullRequestNode: Decodable { let id: String }
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

        let (data, response) = try await transport.data(for: request)
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

    func fetchPullRequestDetail(token: String, reference: PullRequestReference) async throws -> PullRequestDetailContent {
        let parts = reference.repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw URLError(.badURL) }
        let pullPath = "/repos/\(parts[0])/\(parts[1])/pulls/\(reference.number)"

        // The three requests do not depend on each other, so they run at the same time.
        async let pullRequest = decode(PullResponse.self, request: makeRequest(path: pullPath, token: token))
        // GitHub caps this at 100 files per page; later pages are not loaded yet.
        async let fileList = decode([PullFileResponse].self, request: makeRequest(path: "\(pullPath)/files?per_page=100", token: token))
        // Viewed marks and edit rights are a nice-to-have; the diff still loads when GitHub does not return them.
        async let viewerState = try? fetchViewerState(token: token, owner: parts[0], name: parts[1], number: reference.number)
        let pull = try await pullRequest
        let files = try await fileList
        let viewer = await viewerState
        let viewed = viewer?.viewedFiles ?? []
        var detail = pull.detail(reference: reference)
        detail.canEdit = viewer?.canEdit ?? false
        return PullRequestDetailContent(detail: detail,
                                        files: files.map { file in
                                            var file = file.file
                                            file.isViewed = viewed.contains(file.filename)
                                            return file
                                        })
    }

    func setFileViewed(token: String, pullRequestID: String, path: String, viewed: Bool) async throws {
        let mutation = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
        let query = """
        mutation($id: ID!, $path: String!) {
          \(mutation)(input: { pullRequestId: $id, path: $path }) {
            pullRequest { id }
          }
        }
        """
        struct Response: Decodable {}
        _ = try await graphQL(Response.self, query: query, variables: ["id": pullRequestID, "path": path], token: token)
    }

    func fetchPullRequestComments(token: String, reference: PullRequestReference) async throws -> PullRequestComments {
        let (owner, name) = try repoParts(reference.repoFullName)
        // Only the first 100 comments and threads are loaded, like the changed files.
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              comments(first: 100) { nodes { ...CommentFields } }
              reviewThreads(first: 100) {
                nodes {
                  id path line startLine diffSide isResolved isOutdated
                  comments(first: 100) { nodes { ...CommentFields } }
                }
              }
            }
          }
        }

        fragment CommentFields on Comment {
          id
          body
          createdAt
          author { login }
          ... on IssueComment { databaseId url }
          ... on PullRequestReviewComment { databaseId url }
        }
        """
        let response = try await graphQL(CommentsResponse.self,
                                         query: query,
                                         variables: ["owner": owner, "name": name, "number": reference.number],
                                         token: token)
        guard let pullRequest = response.repository?.pullRequest else {
            throw GraphQLError(message: "Pull request \(reference.id) was not found.")
        }
        return PullRequestComments(
            comments: pullRequest.comments.nodes.map(\.comment),
            threads: pullRequest.reviewThreads.nodes.map { thread in
                ReviewThread(id: thread.id,
                             path: thread.path,
                             line: thread.line,
                             startLine: thread.startLine,
                             side: DiffSide(rawValue: thread.diffSide) ?? .right,
                             isResolved: thread.isResolved,
                             isOutdated: thread.isOutdated,
                             comments: thread.comments.nodes.map(\.comment))
            }
        )
    }

    /// Posts through REST so each comment is published right away instead of joining a pending review.
    func postPullRequestComment(token: String, reference: PullRequestReference, comment: NewPullRequestComment) async throws {
        let (owner, name) = try repoParts(reference.repoFullName)
        let repoPath = "/repos/\(owner)/\(name)"
        let path: String
        let body: [String: Any]
        switch comment {
        case let .general(text):
            path = "\(repoPath)/issues/\(reference.number)/comments"
            body = ["body": text]
        case let .inline(text, commitID, anchor):
            path = "\(repoPath)/pulls/\(reference.number)/comments"
            body = ["body": text,
                    "commit_id": commitID,
                    "path": anchor.path,
                    "line": anchor.line,
                    "side": anchor.side.rawValue]
        case let .reply(text, commentID):
            path = "\(repoPath)/pulls/\(reference.number)/comments/\(commentID)/replies"
            body = ["body": text]
        }
        var request = makeRequest(path: path, token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        struct Created: Decodable { let id: Int }
        _ = try await decode(Created.self, request: request)
    }

    /// Replaces the pull request's title, description, or both. Fields left nil are not sent, so GitHub keeps them.
    func editPullRequest(token: String, reference: PullRequestReference, title: String?, body: String?) async throws {
        let (owner, name) = try repoParts(reference.repoFullName)
        var request = makeRequest(path: "/repos/\(owner)/\(name)/pulls/\(reference.number)", token: token)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var fields: [String: String] = [:]
        fields["title"] = title
        fields["body"] = body
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        struct Updated: Decodable { let number: Int }
        _ = try await decode(Updated.self, request: request)
    }

    /// Paths the viewer marked as viewed, and whether they may edit the pull request.
    /// GitHub reports files changed since they were viewed as `DISMISSED`, not `VIEWED`.
    private func fetchViewerState(token: String, owner: String, name: String, number: Int) async throws -> (viewedFiles: Set<String>, canEdit: Bool) {
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              viewerDidAuthor
              viewerCanUpdate
              files(first: 100) { nodes { path viewerViewedState } }
            }
          }
        }
        """
        let response = try await graphQL(ViewerStateResponse.self,
                                         query: query,
                                         variables: ["owner": owner, "name": name, "number": number],
                                         token: token)
        let pullRequest = response.repository?.pullRequest
        let nodes = pullRequest?.files?.nodes ?? []
        let canEdit = pullRequest?.viewerDidAuthor == true && pullRequest?.viewerCanUpdate == true
        return (Set(nodes.filter { $0.viewerViewedState == "VIEWED" }.map(\.path)), canEdit)
    }

    private func repoParts(_ repoFullName: String) throws -> (owner: String, name: String) {
        let parts = repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw URLError(.badURL) }
        return (parts[0], parts[1])
    }

    private func makeRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("GithubPanel", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    private func repoFullName(from item: SearchItem) -> String? {
        let components = item.repositoryURL.pathComponents
        guard components.count >= 4 else { return nil }
        return "\(components[2])/\(components[3])"
    }

    private func decode<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let (data, response) = try await transport.data(for: request)
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

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
            throw GraphQLError(message: "GraphQL HTTP \(http.statusCode): \(raw)", statusCode: http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
    let totalCount: Int
    let items: [SearchItem]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case items
    }
}

private struct SearchItem: Decodable {
    let number: Int
    let repositoryURL: URL
    let title: String
    let htmlURL: URL
    let updatedAt: Date
    let closedAt: Date?
    let pullRequest: SearchPullRequest?

    enum CodingKeys: String, CodingKey {
        case number
        case repositoryURL = "repository_url"
        case title
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
        case pullRequest = "pull_request"
    }
}

private struct SearchPullRequest: Decodable {
    let mergedAt: Date?

    enum CodingKeys: String, CodingKey {
        case mergedAt = "merged_at"
    }
}

private struct PullResponse: Decodable {
    struct User: Decodable {
        let login: String
    }

    struct Ref: Decodable {
        let ref: String
        let sha: String
    }

    let nodeID: String
    let title: String
    let body: String?
    let user: User
    let state: String
    let draft: Bool?
    let mergedAt: Date?
    let base: Ref
    let head: Ref
    let htmlURL: URL
    let createdAt: Date
    let updatedAt: Date?
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let commits: Int

    enum CodingKeys: String, CodingKey {
        case title, body, user, state, draft, base, head, additions, deletions, commits
        case nodeID = "node_id"
        case mergedAt = "merged_at"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case changedFiles = "changed_files"
    }

    func detail(reference: PullRequestReference) -> PullRequestDetail {
        let detailState: PullRequestDetail.State
        if mergedAt != nil {
            detailState = .merged
        } else if state == "closed" {
            detailState = .closed
        } else if draft == true {
            detailState = .draft
        } else {
            detailState = .open
        }
        return PullRequestDetail(reference: reference,
                                 nodeID: nodeID,
                                 title: title,
                                 body: body ?? "",
                                 authorLogin: user.login,
                                 state: detailState,
                                 baseRef: base.ref,
                                 headRef: head.ref,
                                 headSHA: head.sha,
                                 htmlURL: htmlURL,
                                 createdAt: createdAt,
                                 additions: additions,
                                 deletions: deletions,
                                 changedFiles: changedFiles,
                                 commits: commits,
                                 updatedAt: updatedAt)
    }
}

private struct PullFileResponse: Decodable {
    let filename: String
    let previousFilename: String?
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String?

    enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, patch
        case previousFilename = "previous_filename"
    }

    var file: PullRequestFile {
        PullRequestFile(filename: filename,
                        previousFilename: previousFilename,
                        status: PullRequestFile.Status(rawValue: status) ?? .changed,
                        additions: additions,
                        deletions: deletions,
                        patch: patch)
    }
}

private struct ViewerStateResponse: Decodable {
    struct Repository: Decodable { let pullRequest: PullRequest? }
    struct PullRequest: Decodable {
        let viewerDidAuthor: Bool?
        let viewerCanUpdate: Bool?
        let files: Files?
    }
    struct Files: Decodable { let nodes: [File] }
    struct File: Decodable {
        let path: String
        let viewerViewedState: String
    }

    let repository: Repository?
}

private struct CommentsResponse: Decodable {
    struct Repository: Decodable { let pullRequest: PullRequest? }
    struct PullRequest: Decodable {
        let comments: Connection<Comment>
        let reviewThreads: Connection<Thread>
    }
    struct Connection<Node: Decodable>: Decodable { let nodes: [Node] }
    struct Thread: Decodable {
        let id: String
        let path: String
        let line: Int?
        let startLine: Int?
        let diffSide: String
        let isResolved: Bool
        let isOutdated: Bool
        let comments: Connection<Comment>
    }
    struct Comment: Decodable {
        struct Author: Decodable { let login: String }

        let id: String
        let databaseId: Int
        let body: String
        let createdAt: Date
        let url: URL?
        /// Missing when the author's account was deleted.
        let author: Author?

        var comment: PullRequestComment {
            PullRequestComment(id: id,
                               databaseID: databaseId,
                               authorLogin: author?.login ?? "ghost",
                               body: body,
                               createdAt: createdAt,
                               htmlURL: url)
        }
    }

    let repository: Repository?
}

private struct OpenPullRequestsResponse: Decodable {
    let viewer: Viewer

    struct Viewer: Decodable {
        let login: String
        let pullRequests: Connection
    }

    struct Connection: Decodable {
        let nodes: [PullRequestNode]
    }
}

private struct PullRequestNode: Decodable {
    let updatedAt: Date
    let repository: Repository

    struct Repository: Decodable {
        let nameWithOwner: String
    }

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

private struct ReviewRequestsResponse: Decodable {
    let direct: Search
    let all: Search

    struct Search: Decodable {
        let nodes: [Node]

        var rows: [ReviewRequestRow] {
            nodes.map { pr in
                ReviewRequestRow(id: "\(pr.repository.nameWithOwner)#\(pr.number)",
                                 title: pr.title,
                                 number: pr.number,
                                 repoFullName: pr.repository.nameWithOwner,
                                 htmlURL: pr.url,
                                 authorLogin: pr.author?.login,
                                 isDraft: pr.isDraft,
                                 updatedAt: pr.updatedAt)
            }
        }
    }

    struct Node: Decodable {
        let title: String
        let number: Int
        let url: URL
        let updatedAt: Date
        let isDraft: Bool
        let repository: PullRequestNode.Repository
        let author: Author?
    }

    struct Author: Decodable {
        let login: String
    }
}

private struct StatusCheckRollup: Decodable {
    let state: String
    let contexts: StatusCheckContexts?
}

private struct StatusCheckContexts: Decodable {
    let totalCount: Int
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
    var statusCode: Int? = nil

    var errorDescription: String? { message }
}
