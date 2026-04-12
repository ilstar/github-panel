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

    func testFetchOpenPRsDecodesAndSkipsInvalidRepoURLs() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: """
        {
          "items": [
            {
              "number": 42,
              "repository_url": "https://api.github.com/repos/acme/widgets",
              "title": "Ship it",
              "html_url": "https://github.com/acme/widgets/pull/42",
              "updated_at": "2026-04-12T12:34:56Z"
            },
            {
              "number": 99,
              "repository_url": "https://api.github.com/bad",
              "title": "Skip me",
              "html_url": "https://github.com/bad",
              "updated_at": "2026-04-12T12:34:56Z"
            }
          ]
        }
        """)
        let api = GitHubAPI(transport: transport)

        let prs = try await api.fetchOpenPRs(token: "token", username: "fred")

        XCTAssertEqual(prs.count, 1)
        XCTAssertEqual(prs[0].id, "acme/widgets#42")
        XCTAssertEqual(prs[0].repoFullName, "acme/widgets")
        XCTAssertEqual(prs[0].number, 42)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/search/issues")
        XCTAssertTrue(request.url?.query?.contains("author:fred") == true)
        XCTAssertTrue(request.url?.query?.contains("sort:updated-desc") == true)
    }

    func testFetchPullRequestDecodesGraphQLDetail() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: """
        {
          "data": {
            "repository": {
              "pullRequest": {
                "id": "PR_node",
                "title": "Add tests",
                "number": 7,
                "url": "https://github.com/acme/widgets/pull/7",
                "headRefOid": "abc123",
                "isDraft": false,
                "autoMergeRequest": {"enabledAt": "2026-04-12T12:00:00Z"},
                "viewerCanEnableAutoMerge": false,
                "viewerCanDisableAutoMerge": true,
                "isMergeQueueEnabled": true,
                "isInMergeQueue": false,
                "mergeStateStatus": "CLEAN",
                "statusCheckRollup": {"state": "PENDING"}
              }
            }
          }
        }
        """)
        let api = GitHubAPI(transport: transport)

        let pr = try await api.fetchPullRequest(token: "token", repoFullName: "acme/widgets", number: 7)

        XCTAssertEqual(pr.nodeID, "PR_node")
        XCTAssertEqual(pr.title, "Add tests")
        XCTAssertEqual(pr.headSHA, "abc123")
        XCTAssertEqual(pr.status, .pending)
        XCTAssertTrue(pr.isAutoMergeEnabled)
        XCTAssertTrue(pr.canDisableAutoMerge)
        XCTAssertTrue(pr.isMergeQueueEnabled)
        let body = try transport.graphQLBody(at: 0)
        XCTAssertEqual(body.variables["owner"] as? String, "acme")
        XCTAssertEqual(body.variables["name"] as? String, "widgets")
        XCTAssertEqual(body.variables["number"] as? Int, 7)
    }

    func testFetchPullRequestRejectsInvalidRepoName() async {
        let api = GitHubAPI(transport: MockHTTPTransport())

        do {
            _ = try await api.fetchPullRequest(token: "token", repoFullName: "missing-slash", number: 1)
            XCTFail("Expected badURL")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badURL)
        }
    }

    func testGraphQLErrorsAreSurfaced() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"data":null,"errors":[{"message":"Nope"},{"message":"Still nope"}]}"#)
        let api = GitHubAPI(transport: transport)

        do {
            _ = try await api.fetchPullRequest(token: "token", repoFullName: "acme/widgets", number: 7)
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

    func testFetchPRCheckStateMapsCommitStatus() async throws {
        let pendingTransport = MockHTTPTransport()
        pendingTransport.enqueue(json: #"{"state":"pending","total_count":2}"#)
        let pendingAPI = GitHubAPI(transport: pendingTransport)
        let pendingState = try await pendingAPI.fetchPRCheckState(token: "token", pr: sampleInfo(status: .unknown))
        XCTAssertEqual(pendingState, .pending)

        let emptyTransport = MockHTTPTransport()
        emptyTransport.enqueue(json: #"{"state":"failure","total_count":0}"#)
        let emptyAPI = GitHubAPI(transport: emptyTransport)
        let emptyState = try await emptyAPI.fetchPRCheckState(token: "token", pr: sampleInfo(status: .unknown))
        XCTAssertEqual(emptyState, .success)
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

private func sampleInfo(status: CheckState) -> PullRequestInfo {
    PullRequestInfo(nodeID: "PR_node",
                    title: "Title",
                    number: 7,
                    repoFullName: "acme/widgets",
                    htmlURL: URL(string: "https://github.com/acme/widgets/pull/7")!,
                    headSHA: "abc123",
                    isDraft: false,
                    status: status,
                    isAutoMergeEnabled: false,
                    canEnableAutoMerge: true,
                    canDisableAutoMerge: false,
                    isMergeQueueEnabled: false,
                    isInMergeQueue: false,
                    mergeStateStatus: "CLEAN")
}
