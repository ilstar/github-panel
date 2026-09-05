import XCTest
@testable import GithubPanel

final class GitHubAPITests: XCTestCase {
    func testFetchCurrentUserDecodesUserAndSetsHeaders() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"login":"octocat"}"#)
        let api = GitHubAPI(transport: transport)

        let user = try await api.fetchCurrentUser(token: "token-1")

        XCTAssertEqual(user.login, "octocat")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/user")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GithubPanel")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func testFetchOpenPRsReturnsCompleteOrderedRowsInOneRequest() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: openPRResponse)
        let result = try await GitHubAPI(transport: transport).fetchOpenPRs(token: "token")

        XCTAssertEqual(result.login, "octocat")
        XCTAssertEqual(result.rows.map(\.number), [7, 3])
        let pr = try XCTUnwrap(result.rows.first)
        XCTAssertEqual(pr.id, "acme/widgets#7")
        XCTAssertEqual(pr.nodeID, "PR_node")
        XCTAssertEqual(pr.title, "Add tests")
        XCTAssertEqual(pr.repoFullName, "acme/widgets")
        XCTAssertEqual(pr.htmlURL.absoluteString, "https://github.com/acme/widgets/pull/7")
        XCTAssertEqual(pr.updatedAt, ISO8601DateFormatter().date(from: "2026-04-12T12:34:56Z"))
        XCTAssertEqual(pr.headSHA, "abc123")
        XCTAssertEqual(pr.status, .pending)
        XCTAssertFalse(pr.isDraft)
        XCTAssertTrue(pr.isAutoMergeEnabled)
        XCTAssertFalse(pr.canEnableAutoMerge)
        XCTAssertTrue(pr.canDisableAutoMerge)
        XCTAssertTrue(pr.isMergeQueueEnabled)
        XCTAssertFalse(pr.isInMergeQueue)
        XCTAssertEqual(pr.mergeStateStatus, "CLEAN")
        let second = result.rows[1]
        XCTAssertEqual(second.status, .success) // Preserve existing missing-rollup behavior.
        XCTAssertTrue(second.isDraft)
        XCTAssertFalse(second.isAutoMergeEnabled)
        XCTAssertTrue(second.canEnableAutoMerge)
        XCTAssertFalse(second.canDisableAutoMerge)
        XCTAssertFalse(second.isMergeQueueEnabled)
        XCTAssertTrue(second.isInMergeQueue)
        XCTAssertEqual(second.mergeStateStatus, "QUEUED")
        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/graphql")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        let body = try transport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("first: 10, states: [OPEN]"))
        XCTAssertTrue(body.query.contains("field: UPDATED_AT, direction: DESC"))
        XCTAssertTrue(body.query.contains("repository { nameWithOwner }"))
    }

    func testFetchOpenPRsAllowsEmptyResults() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"data":{"viewer":{"login":"octocat","pullRequests":{"nodes":[]}}}}"#)
        let result = try await GitHubAPI(transport: transport).fetchOpenPRs(token: "token")
        XCTAssertEqual(result.login, "octocat")
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testFetchClosedPRsDecodesPaginationAndOutcomeDates() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: """
        {
          "total_count": 17,
          "items": [
            {
              "number": 12,
              "repository_url": "https://api.github.com/repos/acme/widgets",
              "title": "Merged change",
              "html_url": "https://github.com/acme/widgets/pull/12",
              "updated_at": "2026-04-12T12:34:56Z",
              "closed_at": "2026-04-12T12:34:56Z",
              "pull_request": {
                "merged_at": "2026-04-12T12:34:56Z"
              }
            },
            {
              "number": 13,
              "repository_url": "https://api.github.com/repos/acme/widgets",
              "title": "Closed change",
              "html_url": "https://github.com/acme/widgets/pull/13",
              "updated_at": "2026-04-13T12:34:56Z",
              "closed_at": "2026-04-13T12:34:56Z",
              "pull_request": {
                "merged_at": null
              }
            }
          ]
        }
        """)
        let api = GitHubAPI(transport: transport)

        let page = try await api.fetchClosedPRs(token: "token", username: "fred", page: 2, perPage: 10)

        XCTAssertEqual(page.totalCount, 17)
        XCTAssertEqual(page.page, 2)
        XCTAssertEqual(page.perPage, 10)
        XCTAssertFalse(page.hasNextPage)
        XCTAssertEqual(page.rows.map(\.number), [12, 13])
        XCTAssertEqual(page.rows[0].outcome, .merged)
        XCTAssertEqual(page.rows[1].outcome, .closed)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/search/issues")
        XCTAssertTrue(request.url?.query?.contains("author:fred") == true)
        XCTAssertTrue(request.url?.query?.contains("is:closed") == true)
        XCTAssertTrue(request.url?.query?.contains("page=2") == true)
        XCTAssertTrue(request.url?.query?.contains("per_page=10") == true)
    }

    func testGraphQLErrorsAreSurfaced() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"data":null,"errors":[{"message":"Nope"},{"message":"Still nope"}]}"#)
        let api = GitHubAPI(transport: transport)

        do {
            _ = try await api.fetchOpenPRs(token: "token")
            XCTFail("Expected GraphQLError")
        } catch let error as GraphQLError {
            XCTAssertEqual(error.errorDescription, "Nope Still nope")
        }
    }

    func testRESTErrorDecodesGitHubAPIError() async {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"message":"Bad credentials","documentation_url":"https://docs.github.com"}"#, statusCode: 401)
        let api = GitHubAPI(transport: transport)

        do {
            _ = try await api.fetchCurrentUser(token: "bad-token")
            XCTFail("Expected GitHubAPIError")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertEqual(error.errorDescription, "GitHub API error (401): Bad credentials")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMergePullRequestHandlesSuccessFailureAndFallbackDecode() async throws {
        let successTransport = MockHTTPTransport()
        successTransport.enqueue(json: #"{"merged":true}"#)
        let successAPI = GitHubAPI(transport: successTransport)
        let successMerged = try await successAPI.mergePullRequest(token: "token", repoFullName: "acme/widgets", number: 7)
        XCTAssertTrue(successMerged)
        let successRequest = try XCTUnwrap(successTransport.requests.first)
        XCTAssertEqual(successRequest.httpMethod, "PUT")
        XCTAssertEqual(successRequest.url?.path, "/repos/acme/widgets/pulls/7/merge")
        let mergeBody = try XCTUnwrap(successRequest.jsonBody)
        XCTAssertEqual(mergeBody["merge_method"] as? String, "merge")

        let fallbackTransport = MockHTTPTransport()
        fallbackTransport.enqueue(json: #"{"not_merged_field":true}"#)
        let fallbackAPI = GitHubAPI(transport: fallbackTransport)
        let fallbackMerged = try await fallbackAPI.mergePullRequest(token: "token", repoFullName: "acme/widgets", number: 7)
        XCTAssertTrue(fallbackMerged)

        let failureTransport = MockHTTPTransport()
        failureTransport.enqueue(json: #"{"message":"Cannot merge"}"#, statusCode: 405)
        let failureAPI = GitHubAPI(transport: failureTransport)
        do {
            _ = try await failureAPI.mergePullRequest(token: "token", repoFullName: "acme/widgets", number: 7)
            XCTFail("Expected GitHubAPIError")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error.statusCode, 405)
            XCTAssertEqual(error.message, #"{"message":"Cannot merge"}"#)
        }
    }

    func testGraphQLMutationPayloads() async throws {
        let enqueueTransport = MockHTTPTransport()
        enqueueTransport.enqueue(json: #"{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"id":"entry"}}}}"#)
        try await GitHubAPI(transport: enqueueTransport).enqueuePullRequest(token: "token", pullRequestID: "PR_node")
        var body = try enqueueTransport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("enqueuePullRequest"))
        XCTAssertEqual(body.variables["id"] as? String, "PR_node")

        let enableTransport = MockHTTPTransport()
        enableTransport.enqueue(json: #"{"data":{"enablePullRequestAutoMerge":{"pullRequest":{"id":"PR_node"}}}}"#)
        try await GitHubAPI(transport: enableTransport).enableAutoMerge(token: "token", pullRequestID: "PR_node")
        body = try enableTransport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("enablePullRequestAutoMerge"))
        XCTAssertTrue(body.query.contains("mergeMethod: MERGE"))

        let disableTransport = MockHTTPTransport()
        disableTransport.enqueue(json: #"{"data":{"disablePullRequestAutoMerge":{"pullRequest":{"id":"PR_node"}}}}"#)
        try await GitHubAPI(transport: disableTransport).disableAutoMerge(token: "token", pullRequestID: "PR_node")
        body = try disableTransport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("disablePullRequestAutoMerge"))
    }
}

private final class MockHTTPTransport: HTTPTransport {
    struct QueuedResponse {
        let data: Data
        let statusCode: Int
    }

    private(set) var requests: [URLRequest] = []
    private var responses: [QueuedResponse] = []

    func enqueue(json: String, statusCode: Int = 200) {
        responses.append(QueuedResponse(data: Data(json.utf8), statusCode: statusCode))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? QueuedResponse(data: Data(), statusCode: 200)
            : responses.removeFirst()
        let http = HTTPURLResponse(url: request.url!,
                                   statusCode: response.statusCode,
                                   httpVersion: nil,
                                   headerFields: nil)!
        return (response.data, http)
    }

    func graphQLBody(at index: Int) throws -> (query: String, variables: [String: Any]) {
        let request = requests[index]
        let data = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let body = try XCTUnwrap(object)
        return (try XCTUnwrap(body["query"] as? String),
                try XCTUnwrap(body["variables"] as? [String: Any]))
    }
}

private extension URLRequest {
    var jsonBody: [String: Any]? {
        guard let httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
    }
}

private let openPRResponse = """
{"data":{"viewer":{"login":"octocat","pullRequests":{"nodes":[
  {"id":"PR_node","title":"Add tests","number":7,"url":"https://github.com/acme/widgets/pull/7",
   "updatedAt":"2026-04-12T12:34:56Z","repository":{"nameWithOwner":"acme/widgets"},
   "headRefOid":"abc123","isDraft":false,"autoMergeRequest":{"enabledAt":"2026-04-12T12:00:00Z"},
   "viewerCanEnableAutoMerge":false,"viewerCanDisableAutoMerge":true,"isMergeQueueEnabled":true,
   "isInMergeQueue":false,"mergeStateStatus":"CLEAN","statusCheckRollup":{"state":"PENDING"}},
  {"id":"PR_other","title":"Draft","number":3,"url":"https://github.com/acme/widgets/pull/3",
   "updatedAt":"2026-04-11T12:34:56Z","repository":{"nameWithOwner":"acme/widgets"},
   "headRefOid":"def456","isDraft":true,"autoMergeRequest":null,
   "viewerCanEnableAutoMerge":true,"viewerCanDisableAutoMerge":false,"isMergeQueueEnabled":false,
   "isInMergeQueue":true,"mergeStateStatus":"QUEUED","statusCheckRollup":null}
]}}}}
"""
