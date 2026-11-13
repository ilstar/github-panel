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

        XCTAssertEqual(viewModel.lines(for: "a.swift")?.map(\.kind), [.hunk, .deletion, .addition])
        XCTAssertEqual(viewModel.lines(for: "logo.png"), [])
        XCTAssertNil(viewModel.lines(for: "missing.swift"))
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
        var viewed: Set<String> = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in
                                                       detailContent(title: "Viewed", files: [file("a.swift", isViewed: viewed.contains("a.swift"))])
                                                   },
                                                   setViewed: { id, path, isViewed in
                                                       calls.append((id, path, isViewed))
                                                       if isViewed { viewed.insert(path) } else { viewed.remove(path) }
                                                   })
        await viewModel.load()

        viewModel.setViewed(true, filename: "a.swift")
        XCTAssertEqual(viewModel.viewedFiles, ["a.swift"], "Shows before GitHub answers")
        await viewModel.waitForPendingChanges()

        viewModel.setViewed(true, filename: "a.swift")
        viewModel.setViewed(false, filename: "a.swift")
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(viewModel.viewedFiles, [])
        XCTAssertEqual(calls.map(\.0), ["PR_node", "PR_node"])
        XCTAssertEqual(calls.map(\.1), ["a.swift", "a.swift"])
        XCTAssertEqual(calls.map(\.2), [true, false])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
    }

    func testFailedSetViewedStaysShownWithItsErrorUntilDiscarded() async throws {
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Viewed", files: [file("a.swift")]) },
                                                   setViewed: { _, _, _ in
                                                       throw GraphQLError(message: "Resource not accessible")
                                                   })
        await viewModel.load()

        viewModel.setViewed(true, filename: "a.swift")
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(viewModel.viewedFiles, ["a.swift"])
        let failed = try XCTUnwrap(viewModel.change(to: .fileViewed(path: "a.swift")))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error, "Resource not accessible")
        XCTAssertNil(viewModel.errorMessage, "The error shows by the file, not over the pull request")

        viewModel.discard(failed)

        XCTAssertEqual(viewModel.viewedFiles, [])
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
    }

    func testSetViewedBeforeLoadDoesNothing() async {
        var calls = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Viewed") },
                                                   setViewed: { _, _, _ in calls += 1 })

        viewModel.setViewed(true, filename: "a.swift")
        await viewModel.waitForPendingChanges()

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

    func testMonitorLoadsDetailWithSessionToken() async throws {
        let api = FakeGitHubAPI()
        let content = detailContent(title: "From API")
        api.detailHandler = { _ in content }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let viewModel = PullRequestDetailViewModel(reference: reference, monitor: monitor)

        await viewModel.load()

        XCTAssertEqual(viewModel.content, content)
        XCTAssertEqual(monitor.cache.entry(for: reference)?.content, content)
        XCTAssertEqual(api.detailCalls.map(\.token), ["token"])
        XCTAssertEqual(api.detailCalls.map(\.reference), [reference])
    }

    func testMonitorSendsChangesWithSessionTokenAndRefreshesTheList() async throws {
        let api = FakeGitHubAPI()
        api.detailHandler = { [self] _ in
            let content = detailContent(title: "Title", files: [file("a.swift")], canEdit: true)
            var detail = content.detail
            detail.canRequestReviewers = true
            return PullRequestDetailContent(detail: detail, files: content.files)
        }
        api.comments = PullRequestComments(comments: [], threads: [thread("RT_1", path: "a.swift", line: 1)])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let viewModel = PullRequestDetailViewModel(reference: reference, monitor: monitor)
        await viewModel.load()

        viewModel.edit(title: "New")
        viewModel.setViewed(true, filename: "a.swift")
        viewModel.setResolved(true, thread: try XCTUnwrap(viewModel.comments?.threads.first))
        viewModel.setReviewRequested("hubot", kind: .user, requested: true)
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(api.editCalls.map(\.token), ["token"])
        XCTAssertEqual(api.editCalls.map(\.reference), [reference])
        XCTAssertEqual(api.editCalls.map(\.title), ["New"])
        XCTAssertEqual(api.editCalls.map(\.body), [nil])
        XCTAssertEqual(api.setFileViewedCalls.map(\.token), ["token"])
        XCTAssertEqual(api.setFileViewedCalls.map(\.pullRequestID), ["PR_node"])
        XCTAssertEqual(api.setFileViewedCalls.map(\.path), ["a.swift"])
        XCTAssertEqual(api.setResolvedCalls.map(\.token), ["token"])
        XCTAssertEqual(api.setResolvedCalls.map(\.threadID), ["RT_1"])
        XCTAssertEqual(api.setResolvedCalls.map(\.resolved), [true])
        XCTAssertEqual(api.setReviewRequestedCalls.map(\.token), ["token"])
        XCTAssertEqual(api.setReviewRequestedCalls.map(\.name), ["hubot"])
        XCTAssertEqual(api.fetchOpenPRTokens, ["token", "token"], "The title and the review request change My PRs rows")
    }

    func testLoadFetchesCommentsAndGroupsThreadsByFile() async {
        let threadA = thread("t1", path: "a.swift", line: 2)
        let threadB = thread("t2", path: "b.swift", line: 9)
        let comments = PullRequestComments(comments: [comment(1)], threads: [threadA, threadB])
        var fetched: [PullRequestReference] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Comments") },
                                                   fetchComments: { reference, _ in
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

    func testMoreButtonsRaiseTheLimitsAndReloadsKeepThem() async throws {
        var requested: [PullRequestCommentLimits] = []
        var shouldFail = false
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Busy") },
                                                   fetchComments: { [self] _, limits in
                                                       requested.append(limits)
                                                       if shouldFail { throw GraphQLError(message: "Timed out") }
                                                       return PullRequestComments(comments: [comment(limits.comments)], threads: [],
                                                                                  totalCommentCount: 200, totalThreadCount: 200)
                                                   })

        await viewModel.load()
        await viewModel.loadEarlierComments()
        await viewModel.loadMoreThreads()
        shouldFail = true
        await viewModel.loadEarlierComments()
        shouldFail = false
        viewModel.post(.general(body: "Thanks"))
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(requested, [
            PullRequestCommentLimits(comments: 30, threads: 50),
            PullRequestCommentLimits(comments: 60, threads: 50),
            PullRequestCommentLimits(comments: 60, threads: 100),
            PullRequestCommentLimits(comments: 90, threads: 100),
            // The failed load did not count, and posting reloads as much as was shown.
            PullRequestCommentLimits(comments: 60, threads: 100)
        ])
        XCTAssertEqual(viewModel.comments?.comments.map(\.databaseID), [60])
        XCTAssertFalse(viewModel.isLoadingMoreComments)
    }

    func testFailedCommentsLoadKeepsDetailAndShowsError() async {
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Detail") },
                                                   fetchComments: { _, _ in throw GraphQLError(message: "Comments failed") })

        await viewModel.load()

        XCTAssertEqual(viewModel.content?.detail.title, "Detail")
        XCTAssertNil(viewModel.comments)
        XCTAssertEqual(viewModel.errorMessage, "Comments failed")
    }

    func testFailedDetailLoadShowsNoComments() async {
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { _ in throw GraphQLError(message: "Detail failed") },
                                                   fetchComments: { [self] _, _ in
                                                       PullRequestComments(comments: [comment(1)], threads: [])
                                                   })

        await viewModel.load()

        XCTAssertNil(viewModel.content)
        XCTAssertNil(viewModel.comments)
        XCTAssertEqual(viewModel.errorMessage, "Detail failed")
    }

    func testLoadFetchesDetailAndCommentsAtTheSameTime() async {
        let gate = DetailLoadGate()
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in
                                                       // Finishes only once the comments request has started.
                                                       await gate.waitForComments()
                                                       return detailContent(title: "Parallel")
                                                   },
                                                   fetchComments: { _, _ in
                                                       await gate.commentsStarted()
                                                       return .empty
                                                   })

        // Loading one after the other would never finish, so fail after a timeout instead of hanging.
        let loaded = expectation(description: "Loaded")
        Task {
            await viewModel.load()
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5)

        XCTAssertEqual(viewModel.content?.detail.title, "Parallel")
        XCTAssertEqual(viewModel.comments, .empty)
    }

    func testStartsFromTheCacheBeforeLoading() {
        let cache = PullRequestCache()
        let comments = PullRequestComments(comments: [comment(1)], threads: [thread("t1", path: "a.swift", line: 2)])
        cache.store(detailContent(title: "Cached", files: [file("a.swift", patch: "@@ -1 +1 @@\n-a\n+b", isViewed: true)]))
        cache.store(comments, for: reference)

        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Fresh") },
                                                   cache: cache)

        XCTAssertEqual(viewModel.content?.detail.title, "Cached")
        XCTAssertEqual(viewModel.viewedFiles, ["a.swift"])
        XCTAssertEqual(viewModel.lines(for: "a.swift")?.count, 3)
        XCTAssertEqual(viewModel.comments, comments)
        XCTAssertEqual(viewModel.threadIndex(for: "a.swift").threads.map(\.id), ["t1"])
    }

    func testReopeningRestoresChecksComparisonAndExpandedCommentLimits() async {
        let cache = PullRequestCache()
        let checks = PullRequestChecks(checks: [check("ci", .failure, rerun: .workflowRun(1))])
        var comparisons = 0
        var requestedLimits: [PullRequestCommentLimits] = []
        func makeViewModel() -> PullRequestDetailViewModel {
            PullRequestDetailViewModel(reference: reference,
                fetch: { [self] _ in detailContent(title: "Cached", files: [file("a.swift")], lastReviewedSHA: "base") },
                fetchChangedFiles: { [self] _, _, _ in
                    comparisons += 1
                    return [file("a.swift", patch: "@@ -1 +1 @@\n-a\n+b")]
                },
                fetchComments: { _, limits in
                    requestedLimits.append(limits)
                    return .empty
                },
                fetchChecks: { _ in checks }, cache: cache)
        }
        let first = makeViewModel()
        await first.load()
        await first.showFiles(.sinceLastReview)
        await first.loadEarlierComments()
        await first.loadMoreThreads()

        let reopened = makeViewModel()
        XCTAssertEqual(reopened.checks, checks)
        XCTAssertEqual(reopened.filesSinceLastReview, first.filesSinceLastReview)
        await reopened.showFiles(.sinceLastReview)
        XCTAssertEqual(reopened.lines(for: "a.swift"), first.lines(for: "a.swift"))
        XCTAssertEqual(comparisons, 1)
        await reopened.load()
        XCTAssertEqual(requestedLimits.last, PullRequestCommentLimits().addingEarlierComments().addingThreads())
        XCTAssertEqual(comparisons, 1)
    }

    func testCheckRefreshFailureKeepsCachedChecksAndRerunUpdatesCache() async {
        let cache = PullRequestCache()
        var fail = false
        var checks = PullRequestChecks(checks: [check("ci", .failure, rerun: .workflowRun(1))])
        func makeViewModel() -> PullRequestDetailViewModel {
            PullRequestDetailViewModel(reference: reference,
                fetch: { [self] _ in detailContent(title: "Cached") },
                fetchChecks: { _ in
                    if fail { throw TestError(message: "Offline") }
                    return checks
                }, cache: cache)
        }
        let first = makeViewModel()
        await first.load()
        fail = true
        let reopened = makeViewModel()
        await reopened.load()
        XCTAssertEqual(reopened.checks, checks)
        XCTAssertEqual(cache.entry(for: reference)?.checks, checks)
        fail = false
        checks = .empty
        await reopened.rerun(.workflowRun(1))
        XCTAssertEqual(cache.entry(for: reference)?.checks, .empty)
    }

    func testLoadReplacesCachedContentAndStoresIt() async {
        let cache = PullRequestCache()
        cache.store(detailContent(title: "Cached"))
        let comments = PullRequestComments(comments: [comment(2)], threads: [])
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Fresh") },
                                                   fetchComments: { _, _ in comments },
                                                   cache: cache)

        await viewModel.load()

        XCTAssertEqual(viewModel.content?.detail.title, "Fresh")
        XCTAssertEqual(cache.entry(for: reference)?.content.detail.title, "Fresh")
        XCTAssertEqual(cache.entry(for: reference)?.comments, comments)
    }

    func testFailedLoadKeepsCachedContent() async {
        let cache = PullRequestCache()
        cache.store(detailContent(title: "Cached"))
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { _ in throw GraphQLError(message: "Offline") },
                                                   cache: cache)

        await viewModel.load()

        XCTAssertEqual(viewModel.content?.detail.title, "Cached")
        XCTAssertEqual(viewModel.errorMessage, "Offline")
        XCTAssertEqual(cache.entry(for: reference)?.content.detail.title, "Cached")
    }

    func testViewedMarksAndEditsShowFromTheCacheThenLandInIt() async throws {
        let cache = PullRequestCache()
        var title = "Old"
        var body = ""
        var viewed: Set<String> = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in
                                                       detailContent(title: title, body: body,
                                                                     files: [file("a.swift"), file("b.swift", isViewed: viewed.contains("b.swift"))],
                                                                     canEdit: true)
                                                   },
                                                   setViewed: { _, path, isViewed in if isViewed { viewed.insert(path) } },
                                                   edit: { _, newTitle, newBody in
                                                       title = newTitle ?? title
                                                       body = newBody ?? body
                                                   },
                                                   cache: cache)
        await viewModel.load()

        viewModel.setViewed(true, filename: "b.swift")
        viewModel.edit(title: "New", body: "Body")

        let shown = try XCTUnwrap(cache.shownEntry(for: reference)?.content)
        XCTAssertEqual(shown.detail.title, "New")
        XCTAssertEqual(shown.files.filter(\.isViewed).map(\.filename), ["b.swift"])
        XCTAssertEqual(cache.entry(for: reference)?.content.detail.title, "Old", "GitHub's copy waits for GitHub")

        await viewModel.waitForPendingChanges()

        let cached = try XCTUnwrap(cache.entry(for: reference)?.content)
        XCTAssertEqual(cached.detail.title, "New")
        XCTAssertEqual(cached.detail.body, "Body")
        XCTAssertEqual(cached.files.filter(\.isViewed).map(\.filename), ["b.swift"])
        XCTAssertTrue(cache.pendingChanges(for: reference).isEmpty)
    }

    func testPostedCommentsUpdateTheCache() async throws {
        let cache = PullRequestCache()
        var stored = PullRequestComments.empty
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Comments") },
                                                   fetchComments: { _, _ in stored },
                                                   postComment: { [self] _, _ in
                                                       stored = PullRequestComments(comments: [comment(5)], threads: [])
                                                       return 5
                                                   },
                                                   cache: cache)
        await viewModel.load()

        viewModel.post(.general(body: "Hi"))
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(cache.entry(for: reference)?.comments?.comments.map(\.databaseID), [5])
    }

    func testPostSendsCommentThenReloadsComments() async throws {
        var stored = PullRequestComments.empty
        var posted: [(NewPullRequestComment, PullRequestReference)] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Post") },
                                                   fetchComments: { _, _ in stored },
                                                   postComment: { [self] comment, reference in
                                                       posted.append((comment, reference))
                                                       stored = PullRequestComments(comments: [self.comment(9)], threads: [])
                                                       return 9
                                                   })
        await viewModel.load()

        viewModel.post(.general(body: "Looks good"))
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(posted.map(\.0), [.general(body: "Looks good")])
        XCTAssertEqual(posted.map(\.1), [reference])
        XCTAssertEqual(viewModel.comments?.comments.map(\.databaseID), [9])
    }

    func testCommentsShowRightAwayInTheirPlaceAsTheViewersWhileSending() async throws {
        let gate = Gate()
        let target = ReviewThread(id: "t", path: "a.swift", line: 1, startLine: nil, side: .right,
                                  isResolved: false, isOutdated: false, comments: [comment(41)])
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Show") },
                                                   fetchComments: { [self] _, _ in
                                                       PullRequestComments(comments: [comment(1)], threads: [target])
                                                   },
                                                   postComment: { _, _ in
                                                       await gate.wait()
                                                       return 100
                                                   },
                                                   viewerLogin: "monalisa")
        await viewModel.load()
        let anchor = DiffCommentAnchor(path: "a.swift", line: 4, side: .right)

        viewModel.post(.general(body: "Looks good"))
        viewModel.reply("Fixed", to: target)
        viewModel.postInlineComment("Why?", at: anchor)

        let general = try XCTUnwrap(viewModel.comments?.comments.last)
        XCTAssertEqual(general.body, "Looks good")
        XCTAssertEqual(general.authorLogin, "monalisa")
        XCTAssertEqual(viewModel.comments?.totalCommentCount, 2)
        let reply = try XCTUnwrap(viewModel.comments?.threads.first?.comments.last)
        XCTAssertEqual(reply.body, "Fixed")
        let inline = try XCTUnwrap(viewModel.threadIndex(for: "a.swift").threads(at: anchor).first)
        XCTAssertEqual(inline.comments.map(\.body), ["Why?"])
        for shown in [general, reply, inline.comments[0]] {
            XCTAssertEqual(viewModel.status(of: shown)?.isSaving, true, "\(shown.body) shows as sending")
        }
        XCTAssertNil(viewModel.status(of: comment(1)))

        await gate.open()
        await viewModel.waitForPendingChanges()

        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
    }

    func testInlineCommentUsesLoadedHeadCommit() async throws {
        var posted: [NewPullRequestComment] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Inline") },
                                                   postComment: { comment, _ in
                                                       posted.append(comment)
                                                       return posted.count
                                                   })
        let anchor = DiffCommentAnchor(path: "a.swift", line: 4, side: .left)

        viewModel.postInlineComment("Before load", at: anchor)
        await viewModel.load()
        viewModel.postInlineComment("Why?", at: anchor)
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(posted, [.inline(body: "Why?", commitID: "abc123", anchor: anchor)])
    }

    func testReplyTargetsTheThreadsFirstComment() async throws {
        var posted: [NewPullRequestComment] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Reply") },
                                                   postComment: { comment, _ in
                                                       posted.append(comment)
                                                       return posted.count
                                                   })
        let target = ReviewThread(id: "t", path: "a.swift", line: 1, startLine: nil, side: .right,
                                  isResolved: false, isOutdated: false, comments: [comment(41), comment(42)])

        viewModel.reply("Fixed", to: target)
        viewModel.reply("Nothing to reply to", to: thread("empty", path: "a.swift", line: 1, comments: []))
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(posted, [.reply(body: "Fixed", commentID: 41)])
    }

    func testSetResolvedSendsTheThreadAndReloadsComments() async throws {
        var sent: [(String, Bool)] = []
        var resolved = false
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Resolve") },
                                                   fetchComments: { [self] _, _ in
                                                       let target = ReviewThread(id: "t", path: "a.swift", line: 1, startLine: nil,
                                                                                 side: .right, isResolved: resolved, isOutdated: false,
                                                                                 comments: [comment(1)])
                                                       return PullRequestComments(comments: [], threads: [target])
                                                   },
                                                   setResolved: { id, value in
                                                       sent.append((id, value))
                                                       resolved = value
                                                   })
        await viewModel.load()
        let target = try XCTUnwrap(viewModel.comments?.threads.first)

        viewModel.setResolved(true, thread: target)
        XCTAssertEqual(viewModel.comments?.threads.first?.isResolved, true, "Shows before GitHub answers")
        viewModel.setResolved(true, thread: target)
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(sent.map(\.0), ["t"])
        XCTAssertEqual(sent.map(\.1), [true])
        XCTAssertEqual(viewModel.comments?.threads.first?.isResolved, true)
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
    }

    func testFailedSetResolvedStaysShownAndSkipsReload() async throws {
        var commentFetches = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Fail") },
                                                   fetchComments: { [self] _, _ in
                                                       commentFetches += 1
                                                       return PullRequestComments(comments: [], threads: [thread("t", path: "a.swift", line: 1)])
                                                   },
                                                   setResolved: { _, _ in
                                                       throw GitHubAPIError(message: "Forbidden", documentationURL: nil, statusCode: 403)
                                                   })
        await viewModel.load()

        viewModel.setResolved(true, thread: thread("t", path: "a.swift", line: 1))
        await viewModel.waitForPendingChanges()

        let failed = try XCTUnwrap(viewModel.change(to: .threadResolved(threadID: "t")))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error, "GitHub API error (403): Forbidden")
        XCTAssertEqual(viewModel.comments?.threads.first?.isResolved, true)
        XCTAssertEqual(commentFetches, 1)

        viewModel.discard(failed)

        XCTAssertEqual(viewModel.comments?.threads.first?.isResolved, false)
    }

    func testARefusedCommentStaysShownAsFailedWithItsTextAndSkipsReload() async throws {
        var commentFetches = 0
        var shouldFail = true
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Fail") },
                                                   fetchComments: { [self] _, _ in
                                                       commentFetches += 1
                                                       return PullRequestComments(comments: shouldFail ? [] : [comment(8)],
                                                                                  threads: [])
                                                   },
                                                   postComment: { _, _ in
                                                       if shouldFail {
                                                           throw GitHubAPIError(message: "Validation Failed", documentationURL: nil, statusCode: 422)
                                                       }
                                                       return 8
                                                   })
        await viewModel.load()

        viewModel.post(.general(body: "Hi"))
        await viewModel.waitForPendingChanges()

        let failed = try XCTUnwrap(viewModel.comments?.comments.last)
        XCTAssertEqual(failed.body, "Hi")
        let status = try XCTUnwrap(viewModel.status(of: failed))
        XCTAssertEqual(status.failure, "GitHub API error (422): Validation Failed")
        XCTAssertEqual(status.text, "Hi", "The text stays for Retry and Copy")
        XCTAssertEqual(commentFetches, 1, "A refused comment never reached GitHub, so nothing reloads")

        shouldFail = false
        status.retry()
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(viewModel.comments?.comments.map(\.databaseID), [8])
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
    }

    func testMonitorLoadsAndPostsCommentsWithSessionToken() async throws {
        let api = FakeGitHubAPI()
        api.detailHandler = { [self] _ in detailContent(title: "Comments") }
        api.comments = PullRequestComments(comments: [comment(1)], threads: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let viewModel = PullRequestDetailViewModel(reference: reference, monitor: monitor)

        await viewModel.load()
        viewModel.post(.general(body: "Hi"))
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(viewModel.comments, api.comments)
        XCTAssertEqual(api.commentsCalls.map(\.token), ["token", "token"])
        XCTAssertEqual(api.commentsCalls.map(\.reference), [reference, reference])
        XCTAssertEqual(api.postCommentCalls.map(\.token), ["token"])
        XCTAssertEqual(api.postCommentCalls.map(\.comment), [.general(body: "Hi")])
    }

    func testEditTitleSavesOnlyTheTitle() async throws {
        var edits: [(PullRequestReference, String?, String?)] = []
        var fetches = 0
        var title = "Old"
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in
                                                       fetches += 1
                                                       return detailContent(title: title, body: "Old body", files: [file("a.swift")], canEdit: true)
                                                   },
                                                   edit: { reference, newTitle, body in
                                                       edits.append((reference, newTitle, body))
                                                       title = newTitle ?? title
                                                   })
        await viewModel.load()

        viewModel.edit(title: "  New title \n")
        XCTAssertEqual(viewModel.content?.detail.title, "New title", "Shows before GitHub answers")
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(edits.map(\.0), [reference])
        XCTAssertEqual(edits.map(\.1), ["New title"])
        XCTAssertEqual(edits.map(\.2), [nil])
        XCTAssertEqual(viewModel.content?.detail.title, "New title")
        XCTAssertEqual(viewModel.content?.detail.body, "Old body")
        XCTAssertEqual(viewModel.content?.files.map(\.filename), ["a.swift"])
        XCTAssertEqual(fetches, 2, "Reloads once GitHub accepts the edit")
    }

    func testEditBodySavesOnlyTheBodyAndAllowsClearingIt() async throws {
        var edits: [(String?, String?)] = []
        var body = "Old body"
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Title", body: body, canEdit: true) },
                                                   edit: { _, title, newBody in
                                                       edits.append((title, newBody))
                                                       body = newBody ?? body
                                                   })
        await viewModel.load()

        viewModel.edit(body: "New **body**")
        await viewModel.waitForPendingChanges()
        viewModel.edit(body: "")
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(edits.map(\.0), [nil, nil])
        XCTAssertEqual(edits.map(\.1), ["New **body**", ""])
        XCTAssertEqual(viewModel.content?.detail.title, "Title")
        XCTAssertEqual(viewModel.content?.detail.body, "")
    }

    func testEditsMadeBeforeTheFirstSendsCollapseIntoTheLast() async {
        var edits: [String?] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Title", body: "Old", canEdit: true) },
                                                   edit: { _, _, body in edits.append(body) })
        await viewModel.load()

        viewModel.edit(body: "First")
        viewModel.edit(body: "Second")
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(edits, ["Second"])
    }

    func testEditSkipsPullRequestsTheViewerCannotEdit() async throws {
        var edits = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Theirs") },
                                                   edit: { _, _, _ in edits += 1 })
        await viewModel.load()

        viewModel.edit(title: "Mine now")
        viewModel.edit(body: "Mine now")
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(edits, 0)
        XCTAssertEqual(viewModel.content?.detail.title, "Theirs")
    }

    func testEditSkipsBlankTitlesAndEmptyEdits() async throws {
        var edits = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Old", canEdit: true) },
                                                   edit: { _, _, _ in edits += 1 })
        await viewModel.load()

        viewModel.edit(title: "   ")
        viewModel.edit()
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(edits, 0)
        XCTAssertEqual(viewModel.content?.detail.title, "Old")
    }

    func testFailedEditStaysShownWithItsErrorUntilDiscarded() async throws {
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Old", canEdit: true) },
                                                   edit: { _, _, _ in
                                                       throw GitHubAPIError(message: "Forbidden", documentationURL: nil, statusCode: 403)
                                                   })
        await viewModel.load()

        viewModel.edit(title: "New")
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(viewModel.content?.detail.title, "New")
        let failed = try XCTUnwrap(viewModel.change(to: .title))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error, "GitHub API error (403): Forbidden")
        XCTAssertNil(viewModel.errorMessage)

        viewModel.discard(failed)

        XCTAssertEqual(viewModel.content?.detail.title, "Old", "Discarding puts back GitHub's title")
        XCTAssertNil(viewModel.change(to: .title))
    }

    func testRetryingAFailedEditSendsItAgain() async throws {
        var shouldFail = true
        var title = "Old"
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: title, canEdit: true) },
                                                   edit: { _, newTitle, _ in
                                                       if shouldFail { throw GraphQLError(message: "Offline") }
                                                       title = newTitle ?? title
                                                   })
        await viewModel.load()
        viewModel.edit(title: "New")
        await viewModel.waitForPendingChanges()

        shouldFail = false
        viewModel.retry(try XCTUnwrap(viewModel.change(to: .title)))
        await viewModel.waitForPendingChanges()

        XCTAssertNil(viewModel.change(to: .title))
        XCTAssertEqual(viewModel.content?.detail.title, "New")
    }

    func testEditingAFailedFieldAgainReplacesTheFailedChange() async throws {
        var edits: [String?] = []
        var shouldFail = true
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Old", canEdit: true) },
                                                   edit: { _, title, _ in
                                                       edits.append(title)
                                                       if shouldFail { throw GraphQLError(message: "Offline") }
                                                   })
        await viewModel.load()
        viewModel.edit(title: "Typo")
        await viewModel.waitForPendingChanges()

        shouldFail = false
        viewModel.edit(title: "Fixed")
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(edits, ["Typo", "Fixed"])
        XCTAssertTrue(viewModel.pendingChanges.isEmpty, "The failed title was replaced, not left to retry")
    }

    func testSetTaskSavesTheDescriptionWithThatBoxChanged() async {
        var edits: [(String?, String?)] = []
        var body = "- [ ] a\n- [ ] b"
        let cache = PullRequestCache()
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Title", body: body, canEdit: true) },
                                                   edit: { _, title, newBody in
                                                       edits.append((title, newBody))
                                                       body = newBody ?? body
                                                   },
                                                   cache: cache)
        await viewModel.load()

        viewModel.setTask(1, checked: true)
        viewModel.setTask(1, checked: true)
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(edits.map(\.0), [nil])
        XCTAssertEqual(edits.map(\.1), ["- [ ] a\n- [x] b"])
        XCTAssertEqual(viewModel.content?.detail.body, "- [ ] a\n- [x] b")
        XCTAssertEqual(cache.entry(for: reference)?.content.detail.body, "- [ ] a\n- [x] b")
    }

    func testQuickTaskClicksSendInOrderAndTheLastOneWins() async throws {
        var edits: [String?] = []
        var body = "- [ ] a\n- [ ] b"
        let gate = Gate()
        let firstSent = expectation(description: "First click sent")
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Title", body: body, canEdit: true) },
                                                   edit: { _, _, newBody in
                                                       edits.append(newBody)
                                                       if edits.count == 1 {
                                                           firstSent.fulfill()
                                                           await gate.wait()
                                                       }
                                                       body = newBody ?? body
                                                   })
        await viewModel.load()
        var shownBodies: [String] = []
        let subscription = viewModel.$content.sink { shownBodies.append($0?.detail.body ?? "") }

        viewModel.setTask(0, checked: true)
        await fulfillment(of: [firstSent], timeout: 5)
        // These two build on what shows, and the second replaces the first before it sends.
        viewModel.setTask(1, checked: true)
        viewModel.setTask(0, checked: false)
        XCTAssertEqual(viewModel.content?.detail.body, "- [ ] a\n- [x] b")
        shownBodies = []
        await gate.open()
        await viewModel.waitForPendingChanges()
        subscription.cancel()

        XCTAssertEqual(edits, ["- [x] a\n- [ ] b", "- [ ] a\n- [x] b"])
        XCTAssertEqual(viewModel.content?.detail.body, "- [ ] a\n- [x] b")
        XCTAssertFalse(shownBodies.contains("- [x] a\n- [ ] b"),
                       "The reload after the first click doesn't bring its box back while the last click saves")
    }

    func testSetTaskSkipsPullRequestsTheViewerCannotEdit() async {
        var edits = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Theirs", body: "- [ ] a") },
                                                   edit: { _, _, _ in edits += 1 })
        await viewModel.load()

        viewModel.setTask(0, checked: true)
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(edits, 0)
        XCTAssertEqual(viewModel.content?.detail.body, "- [ ] a")
    }

    func testFailedSetTaskKeepsTheBoxUntilDiscarded() async throws {
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Title", body: "- [x] a", canEdit: true) },
                                                   edit: { _, _, _ in
                                                       throw GitHubAPIError(message: "Forbidden", documentationURL: nil, statusCode: 403)
                                                   })
        await viewModel.load()

        viewModel.setTask(0, checked: false)
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(viewModel.content?.detail.body, "- [ ] a")
        let failed = try XCTUnwrap(viewModel.change(to: .body))
        XCTAssertEqual(failed.error, "GitHub API error (403): Forbidden")

        viewModel.discard(failed)

        XCTAssertEqual(viewModel.content?.detail.body, "- [x] a")
    }

    func testTitleEditorNeedsATitle() {
        XCTAssertTrue(PullRequestTitleEditor.canSave("Fix bug"))
        XCTAssertFalse(PullRequestTitleEditor.canSave(" \n "))
    }

    func testBodyEditorPreviewTreatsWhitespaceAsBlank() {
        XCTAssertTrue(PullRequestBodyEditor.isBlank(" \n "))
        XCTAssertFalse(PullRequestBodyEditor.isBlank("## Summary"))
    }

    func testMonitorPostWithoutTokenWaits() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))
        let viewModel = PullRequestDetailViewModel(reference: reference, monitor: monitor)

        viewModel.post(.general(body: "Hi"))
        await viewModel.waitForPendingChanges()

        XCTAssertTrue(api.postCommentCalls.isEmpty)
        XCTAssertEqual(monitor.cache.pendingChanges(for: reference).map(\.state), [.pending])
    }

    func testRequestingAReviewerShowsThemWaitingThenReloads() async {
        var fetchCount = 0
        var requests: [(name: String, kind: PullRequestReviewer.Kind, requested: Bool)] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
            fetch: { [self] _ in
                fetchCount += 1
                let content = detailContent(title: "Title")
                var detail = content.detail
                detail.canRequestReviewers = true
                return PullRequestDetailContent(detail: detail, files: content.files)
            },
            setReviewRequested: { _, name, kind, requested in requests.append((name, kind, requested)) })
        await viewModel.load()

        viewModel.setReviewRequested("acme/web", kind: .team, requested: true)
        XCTAssertEqual(viewModel.reviewRequestsInFlight, ["team:acme/web"])
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(requests.map(\.name), ["acme/web"])
        XCTAssertEqual(requests.map(\.requested), [true])
        XCTAssertEqual(fetchCount, 2)
        XCTAssertTrue(viewModel.reviewRequestsInFlight.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRequestingAReviewerOptimisticallyUpdatesAndShowsFailures() async throws {
        var shouldFail = false
        var reviewers = PullRequestReviewers.none
        let viewModel = PullRequestDetailViewModel(reference: reference,
            fetch: { [self] _ in
                let content = detailContent(title: "Title")
                var detail = content.detail
                detail.canRequestReviewers = true
                detail.reviewers = reviewers
                return PullRequestDetailContent(detail: detail, files: content.files)
            },
            setReviewRequested: { _, name, kind, requested in
                if shouldFail { throw GitHubAPIError(message: "Reviews may only be requested from collaborators", documentationURL: nil) }
                reviewers = reviewers.settingRequest(name: name, kind: kind, requested: requested)
            })
        await viewModel.load()

        viewModel.setReviewRequested("hubot", kind: .user, requested: true)
        XCTAssertTrue(viewModel.content?.detail.reviewers.isRequested("user:hubot") == true, "Shows before GitHub answers")
        await viewModel.waitForPendingChanges()
        XCTAssertTrue(viewModel.content?.detail.reviewers.isRequested("user:hubot") == true)

        shouldFail = true
        viewModel.setReviewRequested("monalisa", kind: .user, requested: true)
        await viewModel.waitForPendingChanges()
        XCTAssertEqual(viewModel.failedReviewRequests.map(\.error),
                       ["GitHub API error: Reviews may only be requested from collaborators"])
        XCTAssertEqual(viewModel.content?.detail.reviewers.reviewers.map(\.name), ["hubot", "monalisa"])
        XCTAssertTrue(viewModel.reviewRequestsInFlight.isEmpty)

        viewModel.discard(try XCTUnwrap(viewModel.failedReviewRequests.first))
        XCTAssertEqual(viewModel.content?.detail.reviewers.reviewers.map(\.name), ["hubot"])
    }

    func testMentionSearchAsksAboutThisPullRequest() async throws {
        var searches: [(PullRequestReference, String)] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
            fetch: { [self] _ in detailContent(title: "Title") },
            searchMentionCandidates: { reference, query in
                searches.append((reference, query))
                return [MentionCandidate(login: "octocat")]
            })

        let candidates = try await viewModel.mentionCandidates(matching: "oct")

        XCTAssertEqual(candidates.map(\.login), ["octocat"])
        XCTAssertEqual(searches.map(\.0), [reference])
        XCTAssertEqual(searches.map(\.1), ["oct"])
    }

    func testRequestingReviewersNeedsPermission() async {
        var requestCount = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
            fetch: { [self] _ in detailContent(title: "Title") },
            setReviewRequested: { _, _, _, _ in requestCount += 1 })
        await viewModel.load()

        viewModel.setReviewRequested("hubot", kind: .user, requested: true)
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(requestCount, 0)
    }

    func testUpdateBranchSendsHeadCommitThenReloads() async {
        var fetchCount = 0
        var updates: [(pullRequestID: String, headSHA: String)] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in
                                                       fetchCount += 1
                                                       // GitHub stops offering the button once the branch is up to date.
                                                       return detailContent(title: "Title", canUpdateBranch: fetchCount == 1)
                                                   },
                                                   updateBranch: { pullRequestID, headSHA in
                                                       updates.append((pullRequestID, headSHA))
                                                   })
        await viewModel.load()
        XCTAssertEqual(viewModel.content?.detail.canUpdateBranch, true)

        await viewModel.updateBranch()

        XCTAssertEqual(updates.map(\.pullRequestID), ["PR_node"])
        XCTAssertEqual(updates.map(\.headSHA), ["abc123"])
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(viewModel.content?.detail.canUpdateBranch, false)
        XCTAssertFalse(viewModel.isUpdatingBranch)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testUpdateBranchRefreshesAfterAnExistingPanelLoadFinishes() async {
        let loadingChecks = Gate()
        let finishChecks = Gate()
        let updated = Gate()
        let cache = PullRequestCache()
        cache.store(detailContent(title: "Before", canUpdateBranch: true))
        await cache.saveNow()
        var didUpdate = false
        var fetchCount = 0
        var checksCount = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
            fetch: { [self] _ in
                fetchCount += 1
                return detailContent(title: didUpdate ? "After" : "Before",
                                     files: [file(didUpdate ? "new.swift" : "old.swift")],
                                     canUpdateBranch: !didUpdate,
                                     headSHA: didUpdate ? "new-head" : "abc123")
            },
            updateBranch: { _, _ in
                didUpdate = true
                await updated.open()
            },
            fetchChecks: { [self] _ in
                checksCount += 1
                let checks = PullRequestChecks(checks: [check("ci", didUpdate ? .pending : .failure)])
                if checksCount == 1 {
                    await loadingChecks.open()
                    await finishChecks.wait()
                }
                return checks
            }, cache: cache)
        let load = Task { await viewModel.load() }
        await loadingChecks.wait()
        XCTAssertTrue(viewModel.isLoading)

        let update = Task { await viewModel.updateBranch() }
        await updated.wait()
        await finishChecks.open()
        await load.value
        await update.value

        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(checksCount, 2)
        XCTAssertEqual(viewModel.content?.detail.title, "After")
        XCTAssertEqual(viewModel.content?.detail.headSHA, "new-head")
        XCTAssertEqual(viewModel.content?.files.map(\.filename), ["new.swift"])
        XCTAssertEqual(viewModel.checks?.checks.map(\.outcome), [.pending])
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isUpdatingBranch)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testUpdateBranchSkipsOtherAuthorsEvenWithWritePermission() async {
        var updateCount = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
            fetch: { [self] _ in detailContent(title: "Title", canUpdateBranch: true, isViewerAuthor: false) },
            updateBranch: { _, _ in updateCount += 1 })
        await viewModel.load()
        XCTAssertEqual(viewModel.content?.detail.offersUpdateBranch, false)
        await viewModel.updateBranch()
        XCTAssertEqual(updateCount, 0)
    }

    func testUpdateBranchSkipsWhenGitHubDoesNotOfferIt() async {
        var updateCount = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Title", canUpdateBranch: false) },
                                                   updateBranch: { _, _ in updateCount += 1 })
        await viewModel.load()

        await viewModel.updateBranch()

        XCTAssertEqual(updateCount, 0)
    }

    func testFailedUpdateBranchShowsErrorAndKeepsTheButton() async {
        var fetchCount = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in
                                                       fetchCount += 1
                                                       return detailContent(title: "Title", canUpdateBranch: true)
                                                   },
                                                   updateBranch: { _, _ in
                                                       throw GitHubAPIError(message: "Merge conflict", documentationURL: nil)
                                                   })
        await viewModel.load()

        await viewModel.updateBranch()

        XCTAssertEqual(viewModel.errorMessage, "GitHub API error: Merge conflict")
        XCTAssertEqual(viewModel.content?.detail.canUpdateBranch, true)
        XCTAssertFalse(viewModel.isUpdatingBranch)
        XCTAssertEqual(fetchCount, 1)
    }

    func testMonitorUpdatesBranchWithSessionTokenAndRefreshesTheList() async throws {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        monitor.branchUpdatePollDelays = []

        try await monitor.updatePullRequestBranch(reference, pullRequestID: "PR_node", expectedHeadSHA: "abc123")

        XCTAssertEqual(api.updateBranchCalls.map(\.token), ["token"])
        XCTAssertEqual(api.updateBranchCalls.map(\.pullRequestID), ["PR_node"])
        XCTAssertEqual(api.updateBranchCalls.map(\.expectedHeadSHA), ["abc123"])
        XCTAssertEqual(api.fetchOpenPRTokens, ["token"])
    }

    func testMonitorUpdateBranchWithoutTokenFails() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))

        do {
            try await monitor.updatePullRequestBranch(reference, pullRequestID: "PR_node", expectedHeadSHA: "abc123")
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is MissingTokenError)
        }
        XCTAssertTrue(api.updateBranchCalls.isEmpty)
    }

    func testLoadFetchesTheChecks() async {
        let checks = PullRequestChecks(checks: [check("a", .failure, rerun: .workflowRun(1))])
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Title") },
                                                   fetchChecks: { _ in checks })
        XCTAssertNil(viewModel.checks)

        await viewModel.load()

        XCTAssertEqual(viewModel.checks, checks)
    }

    func testRerunFailedChecksRunsEachWorkflowOnceThenReloads() async {
        var reruns: [(CheckRerun, String)] = []
        var checksLoads = 0
        let viewModel = PullRequestDetailViewModel(
            reference: reference,
            fetch: { [self] _ in detailContent(title: "Title") },
            fetchChecks: { [self] _ in
                checksLoads += 1
                return PullRequestChecks(checks: [check("a", .failure, rerun: .workflowRun(1)),
                                                  check("b", .failure, rerun: .workflowRun(1)),
                                                  check("c", .failure, rerun: .checkSuite(repositoryID: "R", suiteID: "S")),
                                                  check("d", .success, rerun: .workflowRun(2))])
            },
            rerunChecks: { rerun, repo in reruns.append((rerun, repo)) })
        await viewModel.load()

        await viewModel.rerunFailedChecks()

        XCTAssertEqual(reruns.map(\.0), [.workflowRun(1), .checkSuite(repositoryID: "R", suiteID: "S")])
        XCTAssertEqual(reruns.map(\.1), ["acme/widgets", "acme/widgets"])
        XCTAssertEqual(checksLoads, 2)
        XCTAssertTrue(viewModel.rerunsInFlight.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testFailedRerunShowsTheError() async {
        var checksLoads = 0
        let viewModel = PullRequestDetailViewModel(
            reference: reference,
            fetch: { [self] _ in detailContent(title: "Title") },
            fetchChecks: { [self] _ in
                checksLoads += 1
                return PullRequestChecks(checks: [check("a", .failure, rerun: .workflowRun(1))])
            },
            rerunChecks: { _, _ in throw GitHubAPIError(message: "Must have admin rights", documentationURL: nil) })
        await viewModel.load()

        await viewModel.rerun(.workflowRun(1))

        XCTAssertEqual(viewModel.errorMessage, "GitHub API error: Must have admin rights")
        XCTAssertEqual(checksLoads, 1)
        XCTAssertTrue(viewModel.rerunsInFlight.isEmpty)
    }

    func testMonitorRerunsChecksWithSessionTokenAndRefreshesTheList() async throws {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        try await monitor.rerunChecks(.workflowRun(42), in: "acme/widgets")

        XCTAssertEqual(api.rerunCalls.map(\.token), ["token"])
        XCTAssertEqual(api.rerunCalls.map(\.repoFullName), ["acme/widgets"])
        XCTAssertEqual(api.rerunCalls.map(\.rerun), [.workflowRun(42)])
        XCTAssertEqual(api.fetchOpenPRTokens, ["token"])
    }

    func testMonitorLoadWithoutTokenFails() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))
        let viewModel = PullRequestDetailViewModel(reference: reference, monitor: monitor)

        await viewModel.load()

        XCTAssertEqual(viewModel.errorMessage, MissingTokenError().errorDescription)
        XCTAssertTrue(api.detailCalls.isEmpty)
    }

    // MARK: - Changes since the last review

    func testShowsOnlyTheFilesChangedSinceTheLastReview() async {
        var compared: [(String, String, String)] = []
        var owned = file("a.swift", patch: "@@ -1 +1 @@\n-a\n+b")
        owned.codeOwners = ["@octocat"]
        owned.isOwnedByViewer = true
        let viewModel = PullRequestDetailViewModel(
            reference: reference,
            fetch: { [self] _ in detailContent(title: "Re-review", files: [owned, file("b.swift")], lastReviewedSHA: "old111") },
            fetchChangedFiles: { [self] repo, base, head in
                compared.append((repo, base, head))
                return [file("a.swift", patch: "@@ -1 +1 @@\n-b\n+c")]
            })
        await viewModel.load()
        XCTAssertTrue(viewModel.canShowChangesSinceLastReview)
        XCTAssertEqual(viewModel.fileScope, .all)
        XCTAssertTrue(compared.isEmpty, "The compare loads only once asked for")
        let allLines = viewModel.presentation(for: "a.swift", hideWhitespace: false)

        await viewModel.showFiles(.sinceLastReview)

        XCTAssertEqual(viewModel.fileScope, .sinceLastReview)
        XCTAssertEqual(compared.map(\.0), ["acme/widgets"])
        XCTAssertEqual(compared.map(\.1), ["old111"])
        XCTAssertEqual(compared.map(\.2), ["abc123"])
        XCTAssertEqual(viewModel.filesSinceLastReview?.map(\.filename), ["a.swift"])
        // Code owners come from the pull request's files, since the compare API does not return them.
        XCTAssertEqual(viewModel.filesSinceLastReview?.first?.codeOwners, ["@octocat"])
        XCTAssertEqual(viewModel.filesSinceLastReview?.first?.isOwnedByViewer, true)
        XCTAssertEqual(viewModel.lines(for: "a.swift")?.map(\.text), ["@@ -1 +1 @@", "b", "c"])
        XCTAssertNotEqual(viewModel.presentation(for: "a.swift", hideWhitespace: false), allLines)

        await viewModel.showFiles(.all)
        await viewModel.showFiles(.sinceLastReview)

        XCTAssertEqual(viewModel.lines(for: "a.swift")?.map(\.text), ["@@ -1 +1 @@", "b", "c"])
        XCTAssertEqual(compared.count, 1, "Switching back reuses the loaded changes")
        await viewModel.showFiles(.all)
        XCTAssertEqual(viewModel.lines(for: "a.swift")?.map(\.text), ["@@ -1 +1 @@", "a", "b"])
        XCTAssertEqual(viewModel.presentation(for: "a.swift", hideWhitespace: false), allLines)
    }

    func testNoChangesSinceTheLastReviewSkipsTheCompare() async {
        var compareCount = 0
        let viewModel = PullRequestDetailViewModel(
            reference: reference,
            fetch: { [self] _ in detailContent(title: "Up to date", files: [file("a.swift")], lastReviewedSHA: "abc123") },
            fetchChangedFiles: { _, _, _ in
                compareCount += 1
                return []
            })
        await viewModel.load()

        await viewModel.showFiles(.sinceLastReview)

        XCTAssertEqual(viewModel.fileScope, .sinceLastReview)
        XCTAssertEqual(viewModel.filesSinceLastReview, [])
        XCTAssertEqual(compareCount, 0)
    }

    func testCannotShowChangesSinceTheLastReviewWithoutOne() async {
        let viewModel = PullRequestDetailViewModel(
            reference: reference,
            fetch: { [self] _ in detailContent(title: "New", files: [file("a.swift")]) })
        await viewModel.load()

        await viewModel.showFiles(.sinceLastReview)

        XCTAssertFalse(viewModel.canShowChangesSinceLastReview)
        XCTAssertEqual(viewModel.fileScope, .all)
        XCTAssertNil(viewModel.filesSinceLastReview)
    }

    func testReloadWithANewHeadComparesAgain() async {
        var head = "abc123"
        var compared: [String] = []
        let viewModel = PullRequestDetailViewModel(
            reference: reference,
            fetch: { [self] _ in detailContent(title: "Pushed", files: [file("a.swift")], headSHA: head, lastReviewedSHA: "old111") },
            fetchChangedFiles: { [self] _, _, newHead in
                compared.append(newHead)
                return [file(newHead == "abc123" ? "a.swift" : "b.swift")]
            })
        await viewModel.load()
        await viewModel.showFiles(.sinceLastReview)

        head = "def456"
        await viewModel.load()

        XCTAssertEqual(compared, ["abc123", "def456"])
        XCTAssertEqual(viewModel.filesSinceLastReview?.map(\.filename), ["b.swift"])
    }

    func testFailedCompareShowsTheError() async {
        let viewModel = PullRequestDetailViewModel(
            reference: reference,
            fetch: { [self] _ in detailContent(title: "Gone", files: [file("a.swift")], lastReviewedSHA: "old111") },
            fetchChangedFiles: { _, _, _ in throw GraphQLError(message: "No commit found") })
        await viewModel.load()

        await viewModel.showFiles(.sinceLastReview)

        XCTAssertNil(viewModel.filesSinceLastReview)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoadingChangesSinceLastReview)
    }

    func testANewReviewOnTheHeadLeavesNothingToShowSinceIt() async {
        var lastReviewed: String? = "old111"
        let viewModel = PullRequestDetailViewModel(
            reference: reference,
            fetch: { [self] _ in detailContent(title: "Reviewed", files: [file("a.swift")], lastReviewedSHA: lastReviewed) },
            fetchChangedFiles: { [self] _, _, _ in [file("a.swift")] })
        await viewModel.load()
        await viewModel.showFiles(.sinceLastReview)
        XCTAssertEqual(viewModel.filesSinceLastReview?.count, 1)

        lastReviewed = "abc123"
        await viewModel.load()

        XCTAssertEqual(viewModel.filesSinceLastReview, [])
    }

    private func check(_ id: String, _ outcome: PullRequestCheck.Outcome, rerun: CheckRerun? = nil) -> PullRequestCheck {
        PullRequestCheck(id: id, name: id, workflowName: nil, outcome: outcome, summary: nil,
                         startedAt: nil, completedAt: nil, detailsURL: nil, rerun: rerun)
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

    private func detailContent(title: String, body: String = "", files: [PullRequestFile] = [], canEdit: Bool = false,
                               canUpdateBranch: Bool = false, isViewerAuthor: Bool = true,
                               headSHA: String = "abc123", lastReviewedSHA: String? = nil) -> PullRequestDetailContent {
        var content = PullRequestDetailContent(
            detail: PullRequestDetail(reference: reference,
                                      nodeID: "PR_node",
                                      title: title,
                                      body: body,
                                      authorLogin: "octocat",
                                      state: .open,
                                      baseRef: "main",
                                      headRef: "feature",
                                      headSHA: headSHA,
                                      htmlURL: URL(string: "https://github.com/acme/widgets/pull/7")!,
                                      createdAt: Date(timeIntervalSince1970: 0),
                                      additions: 0,
                                      deletions: 0,
                                      changedFiles: 0,
                                      commits: 1,
                                      canEdit: canEdit,
                                      isViewerAuthor: isViewerAuthor,
                                      canUpdateBranch: canUpdateBranch),
            files: files
        )
        content = PullRequestDetailContent(detail: { var detail = content.detail; detail.lastReviewedSHA = lastReviewedSHA; return detail }(),
                                           files: content.files)
        return content
    }
}

/// Holds back the detail until the comments request starts, proving the two run at the same time.
private actor DetailLoadGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func commentsStarted() {
        started = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func waitForComments() async {
        guard !started else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
