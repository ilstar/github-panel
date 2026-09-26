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
        XCTAssertTrue(body.query.contains("contexts(first: 1) { totalCount }"))
    }

    func testExpectedRollupWithNoContextsIsDecodedAsNoChecks() async throws {
        let noChecksResponse = openPRResponse.replacingOccurrences(
            of: #""state":"PENDING""#,
            with: #""state":"EXPECTED","contexts":{"totalCount":0}"#
        )
        let transport = MockHTTPTransport()
        transport.enqueue(json: noChecksResponse)

        let result = try await GitHubAPI(transport: transport).fetchOpenPRs(token: "token")
        let pr = try XCTUnwrap(result.rows.first)

        XCTAssertEqual(pr.status, .noChecks)
        XCTAssertTrue(pr.canMergeImmediately)
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

    func testFetchReviewRequestsSplitsDirectAndTeamRequestsInOneRequest() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: """
        {"data":{
          "direct":{"nodes":[
            {"id":"PR_a","title":"Direct","number":4,"url":"https://github.com/acme/widgets/pull/4",
             "updatedAt":"2026-04-12T12:34:56Z","isDraft":false,
             "repository":{"nameWithOwner":"acme/widgets"},"author":{"login":"octocat"}}
          ]},
          "all":{"nodes":[
            {"id":"PR_b","title":"Team","number":9,"url":"https://github.com/acme/gears/pull/9",
             "updatedAt":"2026-04-13T12:34:56Z","isDraft":true,
             "repository":{"nameWithOwner":"acme/gears"},"author":null},
            {"id":"PR_a","title":"Direct","number":4,"url":"https://github.com/acme/widgets/pull/4",
             "updatedAt":"2026-04-12T12:34:56Z","isDraft":false,
             "repository":{"nameWithOwner":"acme/widgets"},"author":{"login":"octocat"}}
          ]}
        }}
        """)

        let requests = try await GitHubAPI(transport: transport).fetchReviewRequests(token: "token")

        XCTAssertEqual(requests.fromMe.map(\.id), ["acme/widgets#4"])
        XCTAssertEqual(requests.fromMyTeams.map(\.id), ["acme/gears#9"])
        let direct = try XCTUnwrap(requests.fromMe.first)
        XCTAssertEqual(direct.title, "Direct")
        XCTAssertEqual(direct.authorLogin, "octocat")
        XCTAssertEqual(direct.htmlURL.absoluteString, "https://github.com/acme/widgets/pull/4")
        XCTAssertEqual(direct.updatedAt, ISO8601DateFormatter().date(from: "2026-04-12T12:34:56Z"))
        XCTAssertFalse(direct.isDraft)
        let team = try XCTUnwrap(requests.fromMyTeams.first)
        XCTAssertNil(team.authorLogin)
        XCTAssertTrue(team.isDraft)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.url?.path, "/graphql")
        let body = try transport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("user-review-requested:@me"))
        XCTAssertTrue(body.query.contains(" review-requested:@me"))
        XCTAssertTrue(body.query.contains("is:pr is:open archived:false"))
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

    func testGraphQLHTTPErrorCarriesStatusCode() async {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"message":"Bad credentials"}"#, statusCode: 401)
        let api = GitHubAPI(transport: transport)

        do {
            _ = try await api.fetchOpenPRs(token: "bad-token")
            XCTFail("Expected GraphQLError")
        } catch let error as GraphQLError {
            XCTAssertEqual(error.statusCode, 401)
        } catch {
            XCTFail("Unexpected error: \(error)")
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

    func testFetchPullRequestDetailDecodesPullAndFiles() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: pullDetailResponse)
        transport.enqueue(json: pullFilesResponse)
        transport.enqueue(json: viewedFilesResponse)
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)

        let content = try await GitHubAPI(transport: transport).fetchPullRequestDetail(token: "token", reference: reference)

        let detail = content.detail
        XCTAssertEqual(detail.reference, reference)
        XCTAssertEqual(detail.nodeID, "PR_node")
        XCTAssertEqual(detail.title, "Add tests")
        XCTAssertEqual(detail.body, "Adds **tests**.")
        XCTAssertEqual(detail.authorLogin, "octocat")
        XCTAssertEqual(detail.state, .open)
        XCTAssertEqual(detail.baseRef, "main")
        XCTAssertEqual(detail.headRef, "octocat/tests")
        XCTAssertEqual(detail.htmlURL.absoluteString, "https://github.com/acme/widgets/pull/7")
        XCTAssertEqual(detail.createdAt, ISO8601DateFormatter().date(from: "2026-04-10T08:00:00Z"))
        XCTAssertEqual(detail.additions, 12)
        XCTAssertEqual(detail.deletions, 3)
        XCTAssertEqual(detail.changedFiles, 2)
        XCTAssertEqual(detail.commits, 4)

        XCTAssertEqual(content.files, [
            PullRequestFile(filename: "Sources/New.swift",
                            previousFilename: "Sources/Old.swift",
                            status: .renamed,
                            additions: 1,
                            deletions: 1,
                            patch: "@@ -1 +1 @@\n-a\n+b",
                            isViewed: true),
            PullRequestFile(filename: "logo.png",
                            previousFilename: nil,
                            status: .added,
                            additions: 0,
                            deletions: 0,
                            patch: nil)
        ])

        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/repos/acme/widgets/pulls/7",
            "/repos/acme/widgets/pulls/7/files",
            "/graphql"
        ])
        XCTAssertEqual(transport.requests[1].url?.query, "per_page=100")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token")
        let viewedBody = try transport.graphQLBody(at: 2)
        XCTAssertTrue(viewedBody.query.contains("viewerViewedState"))
        XCTAssertEqual(viewedBody.variables["owner"] as? String, "acme")
        XCTAssertEqual(viewedBody.variables["name"] as? String, "widgets")
        XCTAssertEqual(viewedBody.variables["number"] as? Int, 7)
    }

    func testFetchPullRequestDetailLoadsFilesWhenViewedStateFails() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: pullDetailResponse)
        transport.enqueue(json: pullFilesResponse)
        transport.enqueue(json: #"{"errors":[{"message":"Resource not accessible"}]}"#)

        let content = try await GitHubAPI(transport: transport)
            .fetchPullRequestDetail(token: "token", reference: PullRequestReference(repoFullName: "acme/widgets", number: 7))

        XCTAssertEqual(content.files.map(\.filename), ["Sources/New.swift", "logo.png"])
        XCTAssertFalse(content.files.contains(where: \.isViewed))
    }

    func testSetFileViewedSendsMarkAndUnmarkMutations() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"data":{"markFileAsViewed":{"pullRequest":{"id":"PR_node"}}}}"#)
        transport.enqueue(json: #"{"data":{"unmarkFileAsViewed":{"pullRequest":{"id":"PR_node"}}}}"#)
        let api = GitHubAPI(transport: transport)

        try await api.setFileViewed(token: "token", pullRequestID: "PR_node", path: "Sources/New.swift", viewed: true)
        try await api.setFileViewed(token: "token", pullRequestID: "PR_node", path: "Sources/New.swift", viewed: false)

        let mark = try transport.graphQLBody(at: 0)
        XCTAssertTrue(mark.query.contains("markFileAsViewed(input: { pullRequestId: $id, path: $path })"))
        XCTAssertFalse(mark.query.contains("unmarkFileAsViewed"))
        XCTAssertEqual(mark.variables["id"] as? String, "PR_node")
        XCTAssertEqual(mark.variables["path"] as? String, "Sources/New.swift")
        let unmark = try transport.graphQLBody(at: 1)
        XCTAssertTrue(unmark.query.contains("unmarkFileAsViewed(input: { pullRequestId: $id, path: $path })"))
    }

    func testSetFileViewedSurfacesGraphQLErrors() async {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"errors":[{"message":"Could not resolve to a node"}]}"#)

        do {
            try await GitHubAPI(transport: transport)
                .setFileViewed(token: "token", pullRequestID: "PR_node", path: "a.swift", viewed: true)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Could not resolve to a node")
        }
    }

    func testFetchPullRequestDetailResolvesState() async throws {
        let cases: [(json: String, state: PullRequestDetail.State)] = [
            (#""state":"open","draft":true,"merged_at":null"#, .draft),
            (#""state":"closed","draft":false,"merged_at":null"#, .closed),
            (#""state":"closed","draft":false,"merged_at":"2026-04-11T08:00:00Z""#, .merged)
        ]
        for testCase in cases {
            let transport = MockHTTPTransport()
            transport.enqueue(json: pullDetailResponse.replacingOccurrences(
                of: #""state":"open","draft":false,"merged_at":null"#,
                with: testCase.json
            ))
            transport.enqueue(json: "[]")

            let content = try await GitHubAPI(transport: transport)
                .fetchPullRequestDetail(token: "token", reference: PullRequestReference(repoFullName: "acme/widgets", number: 7))

            XCTAssertEqual(content.detail.state, testCase.state, testCase.json)
        }
    }

    func testFetchPullRequestDetailSurfacesRESTErrors() async {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"message":"Not Found"}"#, statusCode: 404)

        do {
            _ = try await GitHubAPI(transport: transport)
                .fetchPullRequestDetail(token: "token", reference: PullRequestReference(repoFullName: "acme/widgets", number: 7))
            XCTFail("Expected an error")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertEqual(error.message, "Not Found")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testGraphQLMutationPayloads() async throws {
        let enqueueTransport = MockHTTPTransport()
        enqueueTransport.enqueue(json: #"{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"id":"entry"}}}}"#)
        try await GitHubAPI(transport: enqueueTransport).enqueuePullRequest(token: "token", pullRequestID: "PR_node")
        var body = try enqueueTransport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("enqueuePullRequest"))
        XCTAssertEqual(body.variables["id"] as? String, "PR_node")

        let readyTransport = MockHTTPTransport()
        readyTransport.enqueue(json: #"{"data":{"markPullRequestReadyForReview":{"pullRequest":{"id":"PR_node"}}}}"#)
        try await GitHubAPI(transport: readyTransport).markPullRequestReadyForReview(token: "token", pullRequestID: "PR_node")
        body = try readyTransport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("markPullRequestReadyForReview"))
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

private let pullDetailResponse = """
{
  "node_id": "PR_node",
  "title": "Add tests",
  "body": "Adds **tests**.",
  "user": { "login": "octocat" },
  "state":"open","draft":false,"merged_at":null,
  "base": { "ref": "main" },
  "head": { "ref": "octocat/tests" },
  "html_url": "https://github.com/acme/widgets/pull/7",
  "created_at": "2026-04-10T08:00:00Z",
  "additions": 12,
  "deletions": 3,
  "changed_files": 2,
  "commits": 4
}
"""

private let pullFilesResponse = """
[
  {
    "filename": "Sources/New.swift",
    "previous_filename": "Sources/Old.swift",
    "status": "renamed",
    "additions": 1,
    "deletions": 1,
    "patch": "@@ -1 +1 @@\\n-a\\n+b"
  },
  {
    "filename": "logo.png",
    "status": "added",
    "additions": 0,
    "deletions": 0
  }
]
"""

private let viewedFilesResponse = """
{
  "data": {
    "repository": {
      "pullRequest": {
        "files": {
          "nodes": [
            { "path": "Sources/New.swift", "viewerViewedState": "VIEWED" },
            { "path": "logo.png", "viewerViewedState": "DISMISSED" }
          ]
        }
      }
    }
  }
}
"""

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
