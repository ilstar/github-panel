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
        XCTAssertEqual(pr.reviewStatus, PullRequestReviewStatus(decision: .changesRequested,
                                                                approvedBy: ["hubot"],
                                                                changesRequestedBy: ["monalisa"],
                                                                waitingOn: ["octocat", "acme/web"]))
        let second = result.rows[1]
        XCTAssertEqual(second.reviewStatus, .none)
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
        XCTAssertTrue(body.query.contains("first: 50, after: $after, states: [OPEN]"))
        XCTAssertNil(body.variables["after"])
        XCTAssertTrue(body.query.contains("field: UPDATED_AT, direction: DESC"))
        XCTAssertTrue(body.query.contains("nameWithOwner"))
        XCTAssertTrue(body.query.contains("contexts(first: 1) { totalCount }"))
        XCTAssertTrue(body.query.contains("reviewDecision"))
        XCTAssertTrue(body.query.contains("latestOpinionatedReviews(first: 20)"))
        XCTAssertTrue(body.query.contains("... on Team { combinedSlug }"))
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

    func testFetchOpenPRsFollowsPagesAndSkipsRepeatedPullRequests() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: openPRPage(numbers: [9, 8], hasNextPage: true, endCursor: "cursor-1"))
        // 8 was updated between the two requests, so it comes back on the second page too.
        transport.enqueue(json: openPRPage(numbers: [8, 5], hasNextPage: false, endCursor: nil))

        let result = try await GitHubAPI(transport: transport).fetchOpenPRs(token: "token")

        XCTAssertEqual(result.rows.map(\.number), [9, 8, 5])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertNil(try transport.graphQLBody(at: 0).variables["after"])
        XCTAssertEqual(try transport.graphQLBody(at: 1).variables["after"] as? String, "cursor-1")
    }

    func testFetchOpenPRsStopsAfterThePageLimit() async throws {
        let transport = MockHTTPTransport()
        for page in 1...(GitHubAPI.maxOpenPullRequestPages + 1) {
            transport.enqueue(json: openPRPage(numbers: [page], hasNextPage: true, endCursor: "cursor-\(page)"))
        }

        let result = try await GitHubAPI(transport: transport).fetchOpenPRs(token: "token")

        XCTAssertEqual(result.rows.count, GitHubAPI.maxOpenPullRequestPages)
        XCTAssertEqual(transport.requests.count, GitHubAPI.maxOpenPullRequestPages)
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

    func testFetchReviewRequestsDecodesChecksSizeAndWhenIWasAsked() async throws {
        let transport = MockHTTPTransport()
        let asked = """
        "timelineItems":{"nodes":[
          {"createdAt":"2026-04-01T10:00:00Z","requestedReviewer":{"__typename":"User","login":"fred"}},
          {"createdAt":"2026-04-02T10:00:00Z","requestedReviewer":{"__typename":"User","login":"hubot"}},
          {"createdAt":"2026-04-03T10:00:00Z","requestedReviewer":{"__typename":"Team"}},
          {"createdAt":"2026-04-04T10:00:00Z","requestedReviewer":{"__typename":"User","login":"fred"}},
          {"createdAt":"2026-04-05T10:00:00Z","requestedReviewer":null}
        ]}
        """
        let direct = """
        {"id":"PR_a","title":"Direct","number":4,"url":"https://github.com/acme/widgets/pull/4",
         "updatedAt":"2026-04-12T12:34:56Z","isDraft":false,
         "repository":{"nameWithOwner":"acme/widgets"},"author":{"login":"octocat"},
         "additions":120,"deletions":30,"statusCheckRollup":{"state":"FAILURE"},\(asked)}
        """
        let team = """
        {"id":"PR_b","title":"Team","number":9,"url":"https://github.com/acme/gears/pull/9",
         "updatedAt":"2026-04-13T12:34:56Z","isDraft":false,
         "repository":{"nameWithOwner":"acme/gears"},"author":{"login":"hubot"},
         "additions":1,"deletions":0,"statusCheckRollup":null,\(asked)}
        """
        transport.enqueue(json: """
        {"data":{"viewer":{"login":"fred"},"direct":{"nodes":[\(direct)]},"all":{"nodes":[\(team),\(direct)]}}}
        """)

        let requests = try await GitHubAPI(transport: transport).fetchReviewRequests(token: "token")

        let date = ISO8601DateFormatter()
        let mine = try XCTUnwrap(requests.fromMe.first)
        XCTAssertEqual(mine.checkState, .failure)
        XCTAssertEqual(mine.additions, 120)
        XCTAssertEqual(mine.deletions, 30)
        // The latest request to me, not to someone else or a team.
        XCTAssertEqual(mine.requestedAt, date.date(from: "2026-04-04T10:00:00Z"))
        let teams = try XCTUnwrap(requests.fromMyTeams.first)
        XCTAssertNil(teams.checkState)
        XCTAssertEqual(teams.requestedAt, date.date(from: "2026-04-03T10:00:00Z"))
        let body = try transport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("viewer { login }"))
        XCTAssertTrue(body.query.contains("timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 20)"))
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
        let successMerged = try await successAPI.mergePullRequest(token: "token", repoFullName: "acme/widgets", number: 7, method: .merge)
        XCTAssertTrue(successMerged)
        let successRequest = try XCTUnwrap(successTransport.requests.first)
        XCTAssertEqual(successRequest.httpMethod, "PUT")
        XCTAssertEqual(successRequest.url?.path, "/repos/acme/widgets/pulls/7/merge")
        let mergeBody = try XCTUnwrap(successRequest.jsonBody)
        XCTAssertEqual(mergeBody["merge_method"] as? String, "merge")

        let fallbackTransport = MockHTTPTransport()
        fallbackTransport.enqueue(json: #"{"not_merged_field":true}"#)
        let fallbackAPI = GitHubAPI(transport: fallbackTransport)
        let fallbackMerged = try await fallbackAPI.mergePullRequest(token: "token", repoFullName: "acme/widgets", number: 7, method: .merge)
        XCTAssertTrue(fallbackMerged)

        let failureTransport = MockHTTPTransport()
        failureTransport.enqueue(json: #"{"message":"Cannot merge"}"#, statusCode: 405)
        let failureAPI = GitHubAPI(transport: failureTransport)
        do {
            _ = try await failureAPI.mergePullRequest(token: "token", repoFullName: "acme/widgets", number: 7, method: .merge)
            XCTFail("Expected GitHubAPIError")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error.statusCode, 405)
            XCTAssertEqual(error.message, #"{"message":"Cannot merge"}"#)
        }
    }

    func testMergePullRequestSendsTheChosenMethod() async throws {
        for method in MergeMethod.allCases {
            let transport = MockHTTPTransport()
            transport.enqueue(json: #"{"merged":true}"#)

            _ = try await GitHubAPI(transport: transport).mergePullRequest(token: "token", repoFullName: "acme/widgets",
                                                                             number: 7, method: method)

            XCTAssertEqual(transport.requests.first?.jsonBody?["merge_method"] as? String, method.restValue)
        }
        XCTAssertEqual(MergeMethod.allCases.map(\.restValue), ["merge", "squash", "rebase"])
    }

    func testFetchOpenPRsDecodesTheRepositoryMergeMethods() async throws {
        let response = openPRResponse.replacingOccurrences(
            of: #""updatedAt":"2026-04-12T12:34:56Z","repository":{"nameWithOwner":"acme/widgets"}"#,
            with: #""updatedAt":"2026-04-12T12:34:56Z","repository":{"nameWithOwner":"acme/widgets","mergeCommitAllowed":false,"squashMergeAllowed":true,"rebaseMergeAllowed":true,"viewerDefaultMergeMethod":"REBASE"}"#)
        XCTAssertNotEqual(response, openPRResponse)
        let transport = MockHTTPTransport()
        transport.enqueue(json: response)

        let rows = try await GitHubAPI(transport: transport).fetchOpenPRs(token: "token").rows

        XCTAssertEqual(rows[0].mergeMethods, RepositoryMergeMethods(allowed: [.squash, .rebase], suggested: .rebase))
        // Without the settings, only merge commits are assumed, as before.
        XCTAssertEqual(rows[1].mergeMethods, RepositoryMergeMethods(allowed: [.merge], suggested: .merge))
        let body = try transport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("squashMergeAllowed"))
        XCTAssertTrue(body.query.contains("viewerDefaultMergeMethod"))
    }

    func testFetchPullRequestDetailDecodesPullAndFiles() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: pullDetailResponse, path: pullPath)
        transport.enqueue(json: pullFilesResponse, path: filesPath)
        transport.enqueue(json: viewedFilesResponse, path: "/graphql")
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
        XCTAssertEqual(detail.headSHA, "abc123")
        XCTAssertEqual(detail.htmlURL.absoluteString, "https://github.com/acme/widgets/pull/7")
        XCTAssertEqual(detail.createdAt, ISO8601DateFormatter().date(from: "2026-04-10T08:00:00Z"))
        XCTAssertEqual(detail.updatedAt, ISO8601DateFormatter().date(from: "2026-04-12T09:30:00Z"))
        XCTAssertEqual(detail.additions, 12)
        XCTAssertEqual(detail.deletions, 3)
        XCTAssertEqual(detail.changedFiles, 2)
        XCTAssertEqual(detail.commits, 4)
        XCTAssertTrue(detail.canEdit)

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

        // The three requests run at the same time, so their order is not fixed.
        XCTAssertEqual(Set(transport.requests.compactMap { $0.url?.path }), [pullPath, filesPath, "/graphql"])
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(try transport.request(path: filesPath).url?.query, "per_page=100")
        XCTAssertEqual(try transport.request(path: pullPath).value(forHTTPHeaderField: "Authorization"), "Bearer token")
        let graphQLIndex = try XCTUnwrap(transport.requests.firstIndex { $0.url?.path == "/graphql" })
        let viewedBody = try transport.graphQLBody(at: graphQLIndex)
        XCTAssertTrue(viewedBody.query.contains("viewerViewedState"))
        XCTAssertTrue(viewedBody.query.contains("viewerDidAuthor"))
        XCTAssertTrue(viewedBody.query.contains("viewerCanUpdate"))
        XCTAssertEqual(viewedBody.variables["owner"] as? String, "acme")
        XCTAssertEqual(viewedBody.variables["name"] as? String, "widgets")
        XCTAssertEqual(viewedBody.variables["number"] as? Int, 7)
    }

    func testFetchPullRequestDetailLoadsFilesWhenViewedStateFails() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: pullDetailResponse, path: pullPath)
        transport.enqueue(json: pullFilesResponse, path: filesPath)
        transport.enqueue(json: #"{"errors":[{"message":"Resource not accessible"}]}"#, path: "/graphql")

        let content = try await GitHubAPI(transport: transport)
            .fetchPullRequestDetail(token: "token", reference: PullRequestReference(repoFullName: "acme/widgets", number: 7))

        XCTAssertEqual(content.files.map(\.filename), ["Sources/New.swift", "logo.png"])
        XCTAssertFalse(content.files.contains(where: \.isViewed))
        XCTAssertFalse(content.detail.canEdit)
    }

    func testFetchPullRequestDetailOnlyLetsTheAuthorEdit() async throws {
        let cases: [(json: String, canEdit: Bool)] = [
            (#""viewerDidAuthor":true,"viewerCanUpdate":true"#, true),
            (#""viewerDidAuthor":false,"viewerCanUpdate":true"#, false),
            (#""viewerDidAuthor":true,"viewerCanUpdate":false"#, false)
        ]
        for testCase in cases {
            let transport = MockHTTPTransport()
            transport.enqueue(json: pullDetailResponse, path: pullPath)
            transport.enqueue(json: "[]", path: filesPath)
            transport.enqueue(json: #"{"data":{"repository":{"pullRequest":{\#(testCase.json),"files":{"nodes":[]}}}}}"#,
                              path: "/graphql")

            let content = try await GitHubAPI(transport: transport)
                .fetchPullRequestDetail(token: "token", reference: PullRequestReference(repoFullName: "acme/widgets", number: 7))

            XCTAssertEqual(content.detail.canEdit, testCase.canEdit, testCase.json)
            XCTAssertEqual(content.detail.isViewerAuthor, testCase.json.contains(#""viewerDidAuthor":true"#), testCase.json)
        }
    }

    func testEditPullRequestPatchesOnlyTheGivenFields() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"number":7}"#)
        transport.enqueue(json: #"{"number":7}"#)
        let api = GitHubAPI(transport: transport)
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)

        try await api.editPullRequest(token: "token", reference: reference, title: "New title", body: nil)
        try await api.editPullRequest(token: "token", reference: reference, title: nil, body: "")

        XCTAssertEqual(transport.requests.map(\.httpMethod), ["PATCH", "PATCH"])
        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/repos/acme/widgets/pulls/7", "/repos/acme/widgets/pulls/7"])
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(transport.requests[0].jsonBody as? [String: String], ["title": "New title"])
        XCTAssertEqual(transport.requests[1].jsonBody as? [String: String], ["body": ""])
    }

    func testEditPullRequestSurfacesPermissionErrors() async {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"message":"Must have admin rights to Repository."}"#, statusCode: 403)

        do {
            try await GitHubAPI(transport: transport)
                .editPullRequest(token: "token",
                                 reference: PullRequestReference(repoFullName: "acme/widgets", number: 7),
                                 title: "New title",
                                 body: "")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "GitHub API error (403): Must have admin rights to Repository.")
        }
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

    func testSetReviewThreadResolvedSendsResolveAndUnresolveMutations() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"data":{"resolveReviewThread":{"thread":{"id":"RT_1","isResolved":true}}}}"#)
        transport.enqueue(json: #"{"data":{"unresolveReviewThread":{"thread":{"id":"RT_1","isResolved":false}}}}"#)
        let api = GitHubAPI(transport: transport)

        try await api.setReviewThreadResolved(token: "token", threadID: "RT_1", resolved: true)
        try await api.setReviewThreadResolved(token: "token", threadID: "RT_1", resolved: false)

        let resolve = try transport.graphQLBody(at: 0)
        XCTAssertTrue(resolve.query.contains("resolveReviewThread(input: { threadId: $id })"))
        XCTAssertFalse(resolve.query.contains("unresolveReviewThread"))
        XCTAssertEqual(resolve.variables["id"] as? String, "RT_1")
        let unresolve = try transport.graphQLBody(at: 1)
        XCTAssertTrue(unresolve.query.contains("unresolveReviewThread(input: { threadId: $id })"))
    }

    func testSetReviewThreadResolvedSurfacesGraphQLErrors() async {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"errors":[{"message":"Resource not accessible by integration"}]}"#)

        do {
            try await GitHubAPI(transport: transport).setReviewThreadResolved(token: "token", threadID: "RT_1", resolved: true)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Resource not accessible by integration")
        }
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
            ), path: pullPath)
            transport.enqueue(json: "[]", path: filesPath)

            let content = try await GitHubAPI(transport: transport)
                .fetchPullRequestDetail(token: "token", reference: PullRequestReference(repoFullName: "acme/widgets", number: 7))

            XCTAssertEqual(content.detail.state, testCase.state, testCase.json)
        }
    }

    func testFetchPullRequestDetailSurfacesRESTErrors() async {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"message":"Not Found"}"#, statusCode: 404, path: pullPath)
        transport.enqueue(json: "[]", path: filesPath)

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
    }

    func testFetchPullRequestCommentsDecodesCommentsAndThreads() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: commentsResponse)
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)

        let comments = try await GitHubAPI(transport: transport).fetchPullRequestComments(token: "token", reference: reference)

        let date = ISO8601DateFormatter().date(from: "2026-04-10T08:00:00Z")!
        XCTAssertEqual(comments.comments, [
            PullRequestComment(id: "IC_1", databaseID: 11, authorLogin: "octocat", body: "Nice work",
                               createdAt: date, htmlURL: URL(string: "https://github.com/acme/widgets/pull/7#issuecomment-11")),
            PullRequestComment(id: "IC_2", databaseID: 12, authorLogin: "ghost", body: "Deleted user",
                               createdAt: date, htmlURL: nil)
        ])
        XCTAssertEqual(comments.threads, [
            ReviewThread(id: "RT_1", path: "Sources/New.swift", line: 3, startLine: 1, side: .left,
                         isResolved: true, isOutdated: false,
                         comments: [PullRequestComment(id: "RC_1", databaseID: 21, authorLogin: "hubot", body: "Why?",
                                                       createdAt: date, htmlURL: nil)]),
            ReviewThread(id: "RT_2", path: "Sources/New.swift", line: nil, startLine: nil, side: .right,
                         isResolved: false, isOutdated: true, comments: [])
        ])
        let body = try transport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("reviewThreads(first: 100)"))
        XCTAssertEqual(body.variables["owner"] as? String, "acme")
        XCTAssertEqual(body.variables["name"] as? String, "widgets")
        XCTAssertEqual(body.variables["number"] as? Int, 7)
    }

    func testFetchPullRequestCommentsFailsWhenPullRequestIsMissing() async {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"data":{"repository":{"pullRequest":null}}}"#)

        do {
            _ = try await GitHubAPI(transport: transport)
                .fetchPullRequestComments(token: "token", reference: PullRequestReference(repoFullName: "acme/widgets", number: 7))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Pull request acme/widgets#7 was not found.")
        }
    }

    func testPostPullRequestCommentSendsEachKindToItsEndpoint() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"id":1}"#, statusCode: 201)
        transport.enqueue(json: #"{"id":2}"#, statusCode: 201)
        transport.enqueue(json: #"{"id":3}"#, statusCode: 201)
        let api = GitHubAPI(transport: transport)
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)
        let anchor = DiffCommentAnchor(path: "Sources/New.swift", line: 4, side: .left)

        try await api.postPullRequestComment(token: "token", reference: reference, comment: .general(body: "Hello"))
        try await api.postPullRequestComment(token: "token", reference: reference,
                                             comment: .inline(body: "Why?", commitID: "abc123", anchor: anchor))
        try await api.postPullRequestComment(token: "token", reference: reference, comment: .reply(body: "Fixed", commentID: 21))

        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "POST", "POST"])
        XCTAssertEqual(transport.requests.map { $0.url?.path }, [
            "/repos/acme/widgets/issues/7/comments",
            "/repos/acme/widgets/pulls/7/comments",
            "/repos/acme/widgets/pulls/7/comments/21/replies"
        ])
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(transport.requests[0].jsonBody as? [String: String], ["body": "Hello"])
        let inline = try XCTUnwrap(transport.requests[1].jsonBody)
        XCTAssertEqual(inline["body"] as? String, "Why?")
        XCTAssertEqual(inline["commit_id"] as? String, "abc123")
        XCTAssertEqual(inline["path"] as? String, "Sources/New.swift")
        XCTAssertEqual(inline["line"] as? Int, 4)
        XCTAssertEqual(inline["side"] as? String, "LEFT")
        XCTAssertEqual(transport.requests[2].jsonBody as? [String: String], ["body": "Fixed"])
    }

    func testPostPullRequestCommentSurfacesValidationErrors() async {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"message":"Validation Failed"}"#, statusCode: 422)

        do {
            try await GitHubAPI(transport: transport)
                .postPullRequestComment(token: "token",
                                        reference: PullRequestReference(repoFullName: "acme/widgets", number: 7),
                                        comment: .general(body: "Hi"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "GitHub API error (422): Validation Failed")
        }
    }

    func testSubmitReviewPostsTheVerdictAgainstTheLoadedCommit() async throws {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"id":80}"#)
        transport.enqueue(json: #"{"id":81}"#)
        let api = GitHubAPI(transport: transport)
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)

        try await api.submitReview(token: "token", reference: reference,
                                   review: NewPullRequestReview(event: .requestChanges, body: "Please add tests.", commitID: "abc123"))
        try await api.submitReview(token: "token", reference: reference,
                                   review: NewPullRequestReview(event: .approve, body: "", commitID: "abc123"))

        let changes = transport.requests[0]
        XCTAssertEqual(changes.httpMethod, "POST")
        XCTAssertEqual(changes.url?.path, "/repos/acme/widgets/pulls/7/reviews")
        XCTAssertEqual(changes.jsonBody?["event"] as? String, "REQUEST_CHANGES")
        XCTAssertEqual(changes.jsonBody?["body"] as? String, "Please add tests.")
        XCTAssertEqual(changes.jsonBody?["commit_id"] as? String, "abc123")
        // A blank approval sends no body at all.
        XCTAssertEqual(transport.requests[1].jsonBody?["event"] as? String, "APPROVE")
        XCTAssertNil(transport.requests[1].jsonBody?["body"])
    }

    func testSubmitReviewSurfacesGitHubsRefusal() async {
        let transport = MockHTTPTransport()
        transport.enqueue(json: #"{"message":"Unprocessable Entity"}"#, statusCode: 422)

        do {
            try await GitHubAPI(transport: transport).submitReview(
                token: "token", reference: PullRequestReference(repoFullName: "acme/widgets", number: 7),
                review: NewPullRequestReview(event: .approve, body: "", commitID: "abc123"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "GitHub API error (422): Unprocessable Entity")
        }
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
        try await GitHubAPI(transport: enableTransport).enableAutoMerge(token: "token", pullRequestID: "PR_node", mergeMethod: .squash)
        body = try enableTransport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("enablePullRequestAutoMerge"))
        XCTAssertTrue(body.query.contains("mergeMethod: $method"))
        XCTAssertEqual(body.variables["method"] as? String, "SQUASH")

        let disableTransport = MockHTTPTransport()
        disableTransport.enqueue(json: #"{"data":{"disablePullRequestAutoMerge":{"pullRequest":{"id":"PR_node"}}}}"#)
        try await GitHubAPI(transport: disableTransport).disableAutoMerge(token: "token", pullRequestID: "PR_node")
        body = try disableTransport.graphQLBody(at: 0)
        XCTAssertTrue(body.query.contains("disablePullRequestAutoMerge"))
    }
}

private let pullPath = "/repos/acme/widgets/pulls/7"
private let filesPath = "/repos/acme/widgets/pulls/7/files"

private let pullDetailResponse = """
{
  "node_id": "PR_node",
  "title": "Add tests",
  "body": "Adds **tests**.",
  "user": { "login": "octocat" },
  "state":"open","draft":false,"merged_at":null,
  "base": { "ref": "main", "sha": "def456" },
  "head": { "ref": "octocat/tests", "sha": "abc123" },
  "html_url": "https://github.com/acme/widgets/pull/7",
  "created_at": "2026-04-10T08:00:00Z",
  "updated_at": "2026-04-12T09:30:00Z",
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

private let commentsResponse = """
{
  "data": {
    "repository": {
      "pullRequest": {
        "comments": {
          "nodes": [
            { "id": "IC_1", "databaseId": 11, "body": "Nice work", "createdAt": "2026-04-10T08:00:00Z",
              "url": "https://github.com/acme/widgets/pull/7#issuecomment-11", "author": { "login": "octocat" } },
            { "id": "IC_2", "databaseId": 12, "body": "Deleted user", "createdAt": "2026-04-10T08:00:00Z",
              "url": null, "author": null }
          ]
        },
        "reviewThreads": {
          "nodes": [
            { "id": "RT_1", "path": "Sources/New.swift", "line": 3, "startLine": 1, "diffSide": "LEFT",
              "isResolved": true, "isOutdated": false,
              "comments": { "nodes": [
                { "id": "RC_1", "databaseId": 21, "body": "Why?", "createdAt": "2026-04-10T08:00:00Z",
                  "author": { "login": "hubot" } }
              ] } },
            { "id": "RT_2", "path": "Sources/New.swift", "line": null, "startLine": null, "diffSide": "RIGHT",
              "isResolved": false, "isOutdated": true, "comments": { "nodes": [] } }
          ]
        }
      }
    }
  }
}
"""

private let viewedFilesResponse = """
{
  "data": {
    "repository": {
      "pullRequest": {
        "viewerDidAuthor": true,
        "viewerCanUpdate": true,
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
        /// Only a request to this URL path takes the response. Nil matches any request, in order.
        let path: String?
    }

    /// Requests can arrive from several tasks at once, so the queues are guarded by a lock.
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []
    private var responses: [QueuedResponse] = []

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    /// Queues a response. Pass `path` for requests that run at the same time, whose order is not fixed.
    func enqueue(json: String, statusCode: Int = 200, path: String? = nil) {
        lock.withLock {
            responses.append(QueuedResponse(data: Data(json.utf8), statusCode: statusCode, path: path))
        }
    }

    func request(path: String) throws -> URLRequest {
        try XCTUnwrap(requests.first { $0.url?.path == path })
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = lock.withLock {
            recordedRequests.append(request)
            let index = responses.firstIndex { $0.path == nil || $0.path == request.url?.path }
            return index.map { responses.remove(at: $0) }
                ?? QueuedResponse(data: Data(), statusCode: 200, path: nil)
        }
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

/// One page of open pull requests with just the fields every row needs.
private func openPRPage(numbers: [Int], hasNextPage: Bool, endCursor: String?) -> String {
    let nodes = numbers.map { number in
        """
        {"id":"PR_\(number)","title":"PR \(number)","number":\(number),"url":"https://github.com/acme/widgets/pull/\(number)",
         "updatedAt":"2026-04-12T12:34:56Z","repository":{"nameWithOwner":"acme/widgets"},
         "headRefOid":"sha\(number)","isDraft":false,"autoMergeRequest":null,
         "viewerCanEnableAutoMerge":false,"viewerCanDisableAutoMerge":false,"isMergeQueueEnabled":false,
         "isInMergeQueue":false,"mergeStateStatus":"CLEAN","statusCheckRollup":null}
        """
    }
    let cursor = endCursor.map { "\"\($0)\"" } ?? "null"
    return """
    {"data":{"viewer":{"login":"octocat","pullRequests":{
      "pageInfo":{"hasNextPage":\(hasNextPage),"endCursor":\(cursor)},
      "nodes":[\(nodes.joined(separator: ","))]}}}}
    """
}

private let openPRResponse = """
{"data":{"viewer":{"login":"octocat","pullRequests":{"nodes":[
  {"id":"PR_node","title":"Add tests","number":7,"url":"https://github.com/acme/widgets/pull/7",
   "updatedAt":"2026-04-12T12:34:56Z","repository":{"nameWithOwner":"acme/widgets"},
   "headRefOid":"abc123","isDraft":false,"autoMergeRequest":{"enabledAt":"2026-04-12T12:00:00Z"},
   "viewerCanEnableAutoMerge":false,"viewerCanDisableAutoMerge":true,"isMergeQueueEnabled":true,
   "isInMergeQueue":false,"mergeStateStatus":"CLEAN","statusCheckRollup":{"state":"PENDING"},
   "reviewDecision":"CHANGES_REQUESTED",
   "latestOpinionatedReviews":{"nodes":[
     {"state":"APPROVED","author":{"login":"hubot"}},
     {"state":"CHANGES_REQUESTED","author":{"login":"monalisa"}},
     {"state":"DISMISSED","author":{"login":"ghost-reviewer"}},
     {"state":"APPROVED","author":null}]},
   "reviewRequests":{"nodes":[
     {"requestedReviewer":{"login":"octocat"}},
     {"requestedReviewer":{"combinedSlug":"acme/web"}},
     {"requestedReviewer":null}]}},
  {"id":"PR_other","title":"Draft","number":3,"url":"https://github.com/acme/widgets/pull/3",
   "updatedAt":"2026-04-11T12:34:56Z","repository":{"nameWithOwner":"acme/widgets"},
   "headRefOid":"def456","isDraft":true,"autoMergeRequest":null,
   "viewerCanEnableAutoMerge":true,"viewerCanDisableAutoMerge":false,"isMergeQueueEnabled":false,
   "isInMergeQueue":true,"mergeStateStatus":"QUEUED","statusCheckRollup":null}
]}}}}
"""
