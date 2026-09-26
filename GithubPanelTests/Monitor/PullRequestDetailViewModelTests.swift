import XCTest
@testable import GithubPanel

@MainActor
final class PullRequestDetailViewModelTests: XCTestCase {
    private let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)

    func testLoadStoresContent() async {
        let content = detailContent(title: "First")
        var fetched: [PullRequestReference] = []
        let viewModel = PullRequestDetailViewModel(reference: reference) { reference in
            fetched.append(reference)
            return content
        }

        await viewModel.load()

        XCTAssertEqual(fetched, [reference])
        XCTAssertEqual(viewModel.content, content)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadParsesEachFilePatch() async {
        let files = [
            PullRequestFile(filename: "a.swift", previousFilename: nil, status: .modified,
                            additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"),
            PullRequestFile(filename: "logo.png", previousFilename: nil, status: .added,
                            additions: 0, deletions: 0, patch: nil)
        ]
        let content = detailContent(title: "Files", files: files)
        let viewModel = PullRequestDetailViewModel(reference: reference) { _ in content }

        await viewModel.load()

        XCTAssertEqual(viewModel.diffLines["a.swift"]?.map(\.kind), [.hunk, .deletion, .addition])
        XCTAssertEqual(viewModel.diffLines["logo.png"], [])
    }

    func testLoadReadsViewedFiles() async {
        let files = [
            file("a.swift", isViewed: true),
            file("b.swift", isViewed: false)
        ]
        let viewModel = PullRequestDetailViewModel(reference: reference) { [self] _ in
            detailContent(title: "Viewed", files: files)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.viewedFiles, ["a.swift"])
    }

    func testSetViewedUpdatesRightAwayAndSyncs() async {
        var calls: [(String, String, Bool)] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Viewed", files: [file("a.swift")]) },
                                                   setViewed: { id, path, viewed in calls.append((id, path, viewed)) })
        await viewModel.load()

        await viewModel.setViewed(true, filename: "a.swift")
        XCTAssertEqual(viewModel.viewedFiles, ["a.swift"])

        await viewModel.setViewed(true, filename: "a.swift")
        await viewModel.setViewed(false, filename: "a.swift")

        XCTAssertEqual(viewModel.viewedFiles, [])
        XCTAssertEqual(calls.map(\.0), ["PR_node", "PR_node"])
        XCTAssertEqual(calls.map(\.1), ["a.swift", "a.swift"])
        XCTAssertEqual(calls.map(\.2), [true, false])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testFailedSetViewedRestoresMarkAndShowsError() async {
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Viewed", files: [file("a.swift")]) },
                                                   setViewed: { _, _, _ in
                                                       throw GraphQLError(message: "Resource not accessible")
                                                   })
        await viewModel.load()

        await viewModel.setViewed(true, filename: "a.swift")

        XCTAssertEqual(viewModel.viewedFiles, [])
        XCTAssertEqual(viewModel.errorMessage, "Resource not accessible")
    }

    func testSetViewedBeforeLoadDoesNothing() async {
        var calls = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Viewed") },
                                                   setViewed: { _, _, _ in calls += 1 })

        await viewModel.setViewed(true, filename: "a.swift")

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(viewModel.viewedFiles, [])
    }

    func testPresentationHonorsHiddenWhitespace() async {
        let patch = "@@ -1,2 +1,2 @@\n-  a\n-b\n+    a\n+c"
        let viewModel = PullRequestDetailViewModel(reference: reference) { [self] _ in
            detailContent(title: "Diff", files: [file("a.swift", patch: patch)])
        }
        await viewModel.load()

        let shown = viewModel.presentation(for: "a.swift", hideWhitespace: false)
        let hidden = viewModel.presentation(for: "a.swift", hideWhitespace: true)

        XCTAssertEqual(shown.unified.map(\.kind), [.hunk, .deletion, .deletion, .addition, .addition])
        XCTAssertEqual(hidden.unified.map(\.kind), [.hunk, .context, .deletion, .addition])
        XCTAssertEqual(viewModel.presentation(for: "missing.swift", hideWhitespace: false).unified, [])
    }

    func testFailedReloadKeepsPreviousContentAndShowsError() async {
        let content = detailContent(title: "First")
        var shouldFail = false
        let viewModel = PullRequestDetailViewModel(reference: reference) { _ in
            if shouldFail { throw GitHubAPIError(message: "Not Found", documentationURL: nil, statusCode: 404) }
            return content
        }
        await viewModel.load()

        shouldFail = true
        await viewModel.load()

        XCTAssertEqual(viewModel.content, content)
        XCTAssertEqual(viewModel.errorMessage, "GitHub API error (404): Not Found")

        shouldFail = false
        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
    }

    func testMonitorFetchesDetailWithSessionToken() async throws {
        let api = FakeGitHubAPI()
        let content = detailContent(title: "From API")
        api.detailHandler = { _ in content }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        let result = try await monitor.fetchPullRequestDetail(reference)

        XCTAssertEqual(result, content)
        XCTAssertEqual(api.detailCalls.map(\.token), ["token"])
        XCTAssertEqual(api.detailCalls.map(\.reference), [reference])
    }

    func testMonitorSetsFileViewedWithSessionToken() async throws {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        try await monitor.setFileViewed(pullRequestID: "PR_node", path: "a.swift", viewed: true)

        XCTAssertEqual(api.setFileViewedCalls.map(\.token), ["token"])
        XCTAssertEqual(api.setFileViewedCalls.map(\.pullRequestID), ["PR_node"])
        XCTAssertEqual(api.setFileViewedCalls.map(\.path), ["a.swift"])
        XCTAssertEqual(api.setFileViewedCalls.map(\.viewed), [true])
    }

    func testLoadFetchesCommentsAndGroupsThreadsByFile() async {
        let threadA = thread("t1", path: "a.swift", line: 2)
        let threadB = thread("t2", path: "b.swift", line: 9)
        let comments = PullRequestComments(comments: [comment(1)], threads: [threadA, threadB])
        var fetched: [PullRequestReference] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Comments") },
                                                   fetchComments: { reference in
                                                       fetched.append(reference)
                                                       return comments
                                                   })

        await viewModel.load()

        XCTAssertEqual(fetched, [reference])
        XCTAssertEqual(viewModel.comments, comments)
        XCTAssertEqual(viewModel.threadIndex(for: "a.swift").threads, [threadA])
        XCTAssertEqual(viewModel.threadIndex(for: "b.swift").threads, [threadB])
        XCTAssertEqual(viewModel.threadIndex(for: "c.swift").threads, [])
    }

    func testFailedCommentsLoadKeepsDetailAndShowsError() async {
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Detail") },
                                                   fetchComments: { _ in throw GraphQLError(message: "Comments failed") })

        await viewModel.load()

        XCTAssertEqual(viewModel.content?.detail.title, "Detail")
        XCTAssertNil(viewModel.comments)
        XCTAssertEqual(viewModel.errorMessage, "Comments failed")
    }

    func testFailedDetailLoadSkipsComments() async {
        var commentFetches = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { _ in throw GraphQLError(message: "Detail failed") },
                                                   fetchComments: { _ in
                                                       commentFetches += 1
                                                       return .empty
                                                   })

        await viewModel.load()

        XCTAssertEqual(commentFetches, 0)
        XCTAssertEqual(viewModel.errorMessage, "Detail failed")
    }

    func testPostSendsCommentThenReloadsComments() async throws {
        var stored = PullRequestComments.empty
        var posted: [(NewPullRequestComment, PullRequestReference)] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Post") },
                                                   fetchComments: { _ in stored },
                                                   postComment: { [self] comment, reference in
                                                       posted.append((comment, reference))
                                                       stored = PullRequestComments(comments: [self.comment(9)], threads: [])
                                                   })
        await viewModel.load()

        try await viewModel.post(.general(body: "Looks good"))

        XCTAssertEqual(posted.map(\.0), [.general(body: "Looks good")])
        XCTAssertEqual(posted.map(\.1), [reference])
        XCTAssertEqual(viewModel.comments?.comments.map(\.databaseID), [9])
    }

    func testInlineCommentUsesLoadedHeadCommit() async throws {
        var posted: [NewPullRequestComment] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Inline") },
                                                   postComment: { comment, _ in posted.append(comment) })
        let anchor = DiffCommentAnchor(path: "a.swift", line: 4, side: .left)

        try await viewModel.postInlineComment("Before load", at: anchor)
        await viewModel.load()
        try await viewModel.postInlineComment("Why?", at: anchor)

        XCTAssertEqual(posted, [.inline(body: "Why?", commitID: "abc123", anchor: anchor)])
    }

    func testReplyTargetsTheThreadsFirstComment() async throws {
        var posted: [NewPullRequestComment] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Reply") },
                                                   postComment: { comment, _ in posted.append(comment) })
        let target = ReviewThread(id: "t", path: "a.swift", line: 1, startLine: nil, side: .right,
                                  isResolved: false, isOutdated: false, comments: [comment(41), comment(42)])

        try await viewModel.reply("Fixed", to: target)
        try await viewModel.reply("Nothing to reply to", to: thread("empty", path: "a.swift", line: 1, comments: []))

        XCTAssertEqual(posted, [.reply(body: "Fixed", commentID: 41)])
    }

    func testFailedPostThrowsAndSkipsReload() async {
        var commentFetches = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Fail") },
                                                   fetchComments: { _ in
                                                       commentFetches += 1
                                                       return .empty
                                                   },
                                                   postComment: { _, _ in
                                                       throw GitHubAPIError(message: "Validation Failed", documentationURL: nil, statusCode: 422)
                                                   })
        await viewModel.load()

        do {
            try await viewModel.post(.general(body: "Hi"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "GitHub API error (422): Validation Failed")
        }
        XCTAssertEqual(commentFetches, 1)
    }

    func testMonitorFetchesAndPostsCommentsWithSessionToken() async throws {
        let api = FakeGitHubAPI()
        api.comments = PullRequestComments(comments: [comment(1)], threads: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        let result = try await monitor.fetchPullRequestComments(reference)
        try await monitor.postPullRequestComment(.general(body: "Hi"), on: reference)

        XCTAssertEqual(result, api.comments)
        XCTAssertEqual(api.commentsCalls.map(\.token), ["token"])
        XCTAssertEqual(api.commentsCalls.map(\.reference), [reference])
        XCTAssertEqual(api.postCommentCalls.map(\.token), ["token"])
        XCTAssertEqual(api.postCommentCalls.map(\.comment), [.general(body: "Hi")])
    }

    func testMonitorPostWithoutTokenFails() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))

        do {
            try await monitor.postPullRequestComment(.general(body: "Hi"), on: reference)
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is MissingTokenError)
        }
        XCTAssertTrue(api.postCommentCalls.isEmpty)
    }

    func testMonitorFetchWithoutTokenFails() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))

        do {
            _ = try await monitor.fetchPullRequestDetail(reference)
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is MissingTokenError)
        }
        XCTAssertTrue(api.detailCalls.isEmpty)
    }

    private func comment(_ id: Int) -> PullRequestComment {
        PullRequestComment(id: "c\(id)", databaseID: id, authorLogin: "octocat", body: "Comment \(id)",
                           createdAt: Date(timeIntervalSince1970: 0), htmlURL: nil)
    }

    private func thread(_ id: String, path: String, line: Int, comments: [PullRequestComment]? = nil) -> ReviewThread {
        ReviewThread(id: id, path: path, line: line, startLine: nil, side: .right,
                     isResolved: false, isOutdated: false, comments: comments ?? [comment(1)])
    }

    private func file(_ filename: String, patch: String? = nil, isViewed: Bool = false) -> PullRequestFile {
        PullRequestFile(filename: filename, previousFilename: nil, status: .modified,
                        additions: 1, deletions: 1, patch: patch, isViewed: isViewed)
    }

    private func detailContent(title: String, files: [PullRequestFile] = []) -> PullRequestDetailContent {
        PullRequestDetailContent(
            detail: PullRequestDetail(reference: reference,
                                      nodeID: "PR_node",
                                      title: title,
                                      body: "",
                                      authorLogin: "octocat",
                                      state: .open,
                                      baseRef: "main",
                                      headRef: "feature",
                                      headSHA: "abc123",
                                      htmlURL: URL(string: "https://github.com/acme/widgets/pull/7")!,
                                      createdAt: Date(timeIntervalSince1970: 0),
                                      additions: 0,
                                      deletions: 0,
                                      changedFiles: 0,
                                      commits: 1),
            files: files
        )
    }
}
