import XCTest
import GRDB
@testable import GithubPanel

/// The sync engine sending the changes waiting in the details cache.
@MainActor
final class PendingChangeSendingTests: XCTestCase {
    private let clock = TestClock()
    private var session = UUID()

    func testAPullRequestsChangesSendOneAtATimeInOrderWhileOthersSendAlongside() async throws {
        let api = loadingAPI()
        let gate = Gate()
        let firstSent = expectation(description: "First change sent")
        let otherSent = expectation(description: "Other pull request's change sent")
        var sent: [String] = []
        api.editHandler = { reference, title, body in
            sent.append("\(reference.number): \(title ?? body ?? "")")
            if reference.number == 2 { otherSent.fulfill() }
            if title == "First" {
                firstSent.fulfill()
                await gate.wait()
            }
        }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.detail(reference(2)))

        cache.add(.title("First"), to: reference(1))
        cache.add(.body("Second"), to: reference(1))
        await engine.sendPendingChanges()
        await fulfillment(of: [firstSent], timeout: 5)
        cache.add(.title("Other"), to: reference(2))
        await engine.sendPendingChanges(for: reference(2))
        await fulfillment(of: [otherSent], timeout: 5)

        XCTAssertEqual(sent, ["1: First", "2: Other"], "The second change waits for the first")
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.state), [.sending, .pending])

        await gate.open()
        await engine.waitForPendingChanges()

        XCTAssertEqual(sent, ["1: First", "2: Other", "1: Second"])
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
    }

    func testGitHubsNewCopyIsSavedAndTheChangeDeletedInOneTransaction() async throws {
        let api = loadingAPI()
        var title = "Old"
        api.detailHandler = { reference in detailContent(for: reference, title: title) }
        api.editHandler = { _, newTitle, _ in title = newTitle ?? title }
        let store = LocalStore.inMemory()
        let cache = PullRequestCache(store: store, saveDelay: 60)
        let engine = makeEngine(api: api, cache: cache, store: store)
        try await engine.request(.detail(reference(1)))
        await cache.saveNow()
        let commits = CommitObserver()
        store.database.add(transactionObserver: commits)
        var shown: [String] = []
        let subscription = cache.detailUpdates.sink { shown.append($0.1.content.detail.title) }

        cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        await cache.saveNow()
        subscription.cancel()

        XCTAssertFalse(shown.isEmpty)
        XCTAssertEqual(Set(shown), ["New"], "Never flickers back to the old title")
        XCTAssertTrue(commits.tables.contains { savesPullRequest($0) && $0.contains("delete pending_change") },
                      "Saved in one transaction: \(commits.tables)")
        let saved = await store.pullRequestDetails()
        XCTAssertEqual(saved.map(\.entry.content.detail.title), ["New"])
        let pending = await store.pendingChanges()
        XCTAssertTrue(pending.isEmpty)
    }

    func testAChangeWhoseReloadFailsStaysInTheCachedCopy() async throws {
        let api = loadingAPI()
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        api.detailHandler = { _ in throw GraphQLError(message: "Offline") }

        cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(api.editCalls.map(\.title), ["New"])
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "New")
    }

    func testAFailedChangeStaysUntilItIsRetriedOrDiscarded() async throws {
        let api = loadingAPI()
        var shouldFail = true
        var title = "Old"
        api.detailHandler = { reference in detailContent(for: reference, title: title) }
        api.editHandler = { _, newTitle, _ in
            if shouldFail { throw GraphQLError(message: "Nope") }
            title = newTitle ?? title
        }
        let store = LocalStore.inMemory()
        let cache = PullRequestCache(store: store)
        let engine = makeEngine(api: api, cache: cache, store: store)
        try await engine.request(.detail(reference(1)))

        let change = cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.state), [.failed])
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.error), ["Nope"])
        XCTAssertEqual(cache.shownEntry(for: reference(1))?.content.detail.title, "New")
        await cache.saveNow()
        let saved = await store.pendingChanges()
        XCTAssertEqual(saved.map(\.state), [.failed], "Failed stays failed after a restart")

        // A failed change doesn't hold up later ones.
        cache.add(.fileViewed(pullRequestID: "node-1", path: "a.swift", viewed: true), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        XCTAssertEqual(api.setFileViewedCalls.count, 1)
        XCTAssertEqual(api.editCalls.count, 1, "A failed change waits for Retry")

        shouldFail = false
        cache.markPending(change.id)
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "New")

        shouldFail = true
        let discarded = cache.add(.title("Newer"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        cache.discard(discarded.id)

        XCTAssertEqual(cache.shownEntry(for: reference(1))?.content.detail.title, "New", "Back to GitHub's title")
        await cache.saveNow()
        let afterDiscard = await store.pendingChanges()
        XCTAssertTrue(afterDiscard.isEmpty)
    }

    func testChangesLeftByTheLastRunAreSentAgain() async throws {
        let api = loadingAPI()
        let store = LocalStore.inMemory()
        let lastRun = PullRequestCache(store: store)
        await lastRun.waitForRestore()
        lastRun.add(.title("Waiting"), to: reference(1))
        let sending = lastRun.add(.threadResolved(threadID: "T", resolved: true), to: reference(2))
        lastRun.markSending(sending.id)
        let failed = lastRun.add(.body("Refused"), to: reference(1))
        lastRun.markFailed(failed.id, error: "Nope")
        await lastRun.saveNow()

        let cache = PullRequestCache(store: store)
        let engine = makeEngine(api: api, cache: cache, store: store)
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(api.editCalls.map(\.title), ["Waiting"])
        XCTAssertEqual(api.setResolvedCalls.map(\.threadID), ["T"], "A change that was sending when the app quit is sent again")
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.id), [failed.id], "A failed change waits for the user")
        XCTAssertTrue(cache.pendingChanges(for: reference(2)).isEmpty)
    }

    func testANewTokenDropsTheOldAccountsChanges() async throws {
        let api = FakeGitHubAPI()
        api.detailHandler = { reference in detailContent(for: reference) }
        let gate = Gate()
        let sent = expectation(description: "First change sent")
        api.editHandler = { _, _, _ in
            sent.fulfill()
            await gate.wait()
        }
        let store = LocalStore.inMemory()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "old"), store: store)
        let cache = monitor.cache
        try await monitor.syncEngine.request(.detail(reference(1)))
        cache.add(.title("Sending"), to: reference(1))
        cache.add(.body("Waiting"), to: reference(1))
        await monitor.syncEngine.sendPendingChanges()
        await fulfillment(of: [sent], timeout: 5)

        monitor.saveToken("new")
        await gate.open()
        await monitor.syncEngine.sendPendingChanges()
        await monitor.syncEngine.waitForPendingChanges()
        await cache.saveNow()

        XCTAssertEqual(api.editCalls.map(\.token), ["old"], "Nothing the old account changed is sent with the new token")
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        let saved = await store.pendingChanges()
        XCTAssertTrue(saved.isEmpty)
    }

    func testChangesWaitOutTheBackoffAsPending() async throws {
        let api = loadingAPI()
        api.checksHandler = { _ in throw GitHubAPIError(message: "Rate limited", documentationURL: nil, statusCode: 403) }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        await XCTAssertThrowsAsync(try await engine.request(.checks(reference(1))))

        cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertTrue(api.editCalls.isEmpty)
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.state), [.pending])

        clock.now += 90
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(api.editCalls.map(\.title), ["New"])
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
    }

    func testARefusedWriteFailsWithoutBackingOff() async throws {
        let api = loadingAPI()
        api.editHandler = { _, _, _ in throw GitHubAPIError(message: "Forbidden", documentationURL: nil, statusCode: 403) }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))

        cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        try await engine.request(.checks(reference(1)))

        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.state), [.failed])
        XCTAssertEqual(api.checksCalls.count, 1, "GitHub refuses writes it doesn't allow with 403 too")
    }

    func testAResolvedThreadReloadsTheCommentsAndTitlesReloadMyPRs() async throws {
        let api = loadingAPI()
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))

        cache.add(.threadResolved(threadID: "T", resolved: true), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        XCTAssertEqual(api.commentsCalls.count, 2)
        XCTAssertEqual(api.detailCalls.count, 1)
        XCTAssertTrue(api.fetchOpenPRTokens.isEmpty)

        cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        XCTAssertEqual(api.detailCalls.count, 2)
        XCTAssertEqual(api.fetchOpenPRTokens, ["token"])
    }

    // MARK: - Comments

    func testAPostedCommentShowsOnceThroughTheConfirmingReloadSavedInOneTransaction() async throws {
        let api = loadingAPI()
        var posted: [PullRequestComment] = []
        api.commentsHandler = { _, _ in PullRequestComments(comments: posted, threads: []) }
        api.postCommentHandler = { comment, _ in
            posted.append(PullRequestComment(id: "IC_7", databaseID: 7, authorLogin: "monalisa", body: comment.body,
                                             createdAt: Date(), htmlURL: nil))
            return 7
        }
        let store = LocalStore.inMemory()
        let cache = PullRequestCache(store: store, saveDelay: 60)
        let engine = makeEngine(api: api, cache: cache, store: store)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))
        await cache.saveNow()
        let commits = CommitObserver()
        store.database.add(transactionObserver: commits)
        var shownCounts: [Int] = []
        let subscription = cache.detailUpdates.sink { shownCounts.append($0.1.comments?.comments.count ?? 0) }

        cache.add(.comment(.general(body: "Hi"), authorLogin: "monalisa"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        await cache.saveNow()
        subscription.cancel()

        XCTAssertFalse(shownCounts.isEmpty)
        XCTAssertEqual(Set(shownCounts), [1], "Shows from the moment it's posted, and never twice")
        XCTAssertEqual(cache.shownEntry(for: reference(1))?.comments?.comments.map(\.id), ["IC_7"])
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        XCTAssertTrue(commits.tables.contains { savesPullRequest($0) && $0.contains("delete pending_change") },
                      "Saved in one transaction: \(commits.tables)")
        let saved = await store.pullRequestDetails()
        XCTAssertEqual(saved.first?.entry.comments?.comments.map(\.id), ["IC_7"])
        let pending = await store.pendingChanges()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCommentsLeftByTheLastRunFailInsteadOfBeingSentAgain() async throws {
        let api = loadingAPI()
        let store = LocalStore.inMemory()
        let lastRun = PullRequestCache(store: store)
        await lastRun.waitForRestore()
        let waiting = lastRun.add(.comment(.general(body: "Waiting"), authorLogin: "monalisa"), to: reference(1))
        let sending = lastRun.add(.comment(.reply(body: "Sending", commentID: 41), authorLogin: "monalisa"),
                                  to: reference(1))
        lastRun.markSending(sending.id)
        let posted = lastRun.add(.comment(.general(body: "Posted"), authorLogin: "monalisa"), to: reference(1))
        lastRun.markSending(posted.id)
        lastRun.markPosted(posted.id, commentID: 9)
        let title = lastRun.add(.title("Title"), to: reference(2))
        lastRun.markSending(title.id)
        await lastRun.saveNow()

        let cache = PullRequestCache(store: store)
        let engine = makeEngine(api: api, cache: cache, store: store)
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertTrue(api.postCommentCalls.isEmpty, "A comment may have posted, so it's never sent again on its own")
        XCTAssertEqual(api.editCalls.map(\.title), ["Title"], "Safe changes are still sent again")
        let changes = cache.pendingChanges(for: reference(1))
        XCTAssertEqual(changes.map(\.id), [waiting.id, sending.id], "One GitHub posted is dropped; the next load shows it")
        XCTAssertEqual(changes.map(\.state), [.failed, .failed])
        XCTAssertEqual(changes.map(\.error), [PendingChange.notSentAfterQuitError, PendingChange.notSentAfterQuitError])
        let saved = await store.pendingChanges()
        XCTAssertEqual(saved.map(\.id), [waiting.id, sending.id])
        XCTAssertEqual(saved.map(\.state), [.failed, .failed])
    }

    func testACommentThatMayHaveReachedGitHubFailsWithoutBeingSentAgain() async throws {
        let api = loadingAPI()
        api.postCommentHandler = { _, _ in throw URLError(.timedOut) }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))

        cache.add(.comment(.general(body: "Hi"), authorLogin: "monalisa"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(api.postCommentCalls.count, 1)
        let failed = try XCTUnwrap(cache.pendingChanges(for: reference(1)).first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(failed.error?.hasSuffix("GitHub may have posted it anyway, so check before you retry.") == true,
                      failed.error ?? "")
        XCTAssertEqual(api.commentsCalls.count, 2, "Reloads, so a comment GitHub did post shows")
    }

    func testOnlyFailuresAfterGitHubMayHaveActedCountAsMaybePosted() {
        XCTAssertTrue(SyncEngine.mayHaveReachedGitHub(URLError(.timedOut)))
        XCTAssertTrue(SyncEngine.mayHaveReachedGitHub(URLError(.networkConnectionLost)))
        XCTAssertTrue(SyncEngine.mayHaveReachedGitHub(GitHubAPIError(message: "Bad gateway", documentationURL: nil,
                                                                      statusCode: 502)))
        XCTAssertFalse(SyncEngine.mayHaveReachedGitHub(URLError(.notConnectedToInternet)))
        XCTAssertFalse(SyncEngine.mayHaveReachedGitHub(GitHubAPIError(message: "Validation Failed", documentationURL: nil,
                                                                       statusCode: 422)))
    }

    func testRetrySendsTheSameCommentAgainAndDiscardDropsIt() async throws {
        let api = loadingAPI()
        var shouldFail = true
        api.postCommentHandler = { _, _ in
            if shouldFail { throw GitHubAPIError(message: "Validation Failed", documentationURL: nil, statusCode: 422) }
            return 5
        }
        let store = LocalStore.inMemory()
        let cache = PullRequestCache(store: store)
        let engine = makeEngine(api: api, cache: cache, store: store)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))

        let retried = cache.add(.comment(.general(body: "Retry me"), authorLogin: nil), to: reference(1))
        let discarded = cache.add(.comment(.general(body: "Drop me"), authorLogin: nil), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.state), [.failed, .failed],
                       "A comment doesn't replace an earlier one")
        XCTAssertEqual(api.commentsCalls.count, 1, "GitHub refused them, so nothing reloads")

        shouldFail = false
        cache.markPending(retried.id)
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        cache.discard(discarded.id)
        await cache.saveNow()

        XCTAssertEqual(api.postCommentCalls.map(\.comment), [.general(body: "Retry me"), .general(body: "Drop me"),
                                                            .general(body: "Retry me")])
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        XCTAssertEqual(cache.shownEntry(for: reference(1))?.comments?.comments, [])
        let saved = await store.pendingChanges()
        XCTAssertTrue(saved.isEmpty)
    }

    func testAnInlineCommentKeepsTheCommitItWasWrittenOnWhenTheHeadMoves() async throws {
        let api = FakeGitHubAPI()
        var head = "sha-old"
        api.detailHandler = { [unowned self] _ in content(headSHA: head) }
        api.postCommentHandler = { _, _ in
            throw GitHubAPIError(message: "Validation Failed", documentationURL: nil, statusCode: 422)
        }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))
        let anchor = DiffCommentAnchor(path: "a.swift", line: 4, side: .right)

        cache.add(.comment(.inline(body: "Why?", commitID: "sha-old", anchor: anchor), authorLogin: nil), to: reference(1))
        XCTAssertEqual(cache.shownEntry(for: reference(1))?.comments?.threads.first?.anchor, anchor)
        head = "sha-new"
        try await engine.request(.detail(reference(1)))

        let moved = try XCTUnwrap(cache.shownEntry(for: reference(1))?.comments?.threads.first)
        XCTAssertNil(moved.anchor, "Not shown on a line of the new diff")
        XCTAssertTrue(moved.isOutdated)

        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(api.postCommentCalls.map(\.comment), [.inline(body: "Why?", commitID: "sha-old", anchor: anchor)])
        let failed = try XCTUnwrap(cache.pendingChanges(for: reference(1)).first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error, "New commits were pushed after you wrote this comment, and GitHub no longer takes "
                       + "it on the commit you wrote it on. Copy it and comment on the current diff.")
    }

    // MARK: - Reviews

    func testAPendingReviewsChangesSendInOrderWithTheIDOfTheReviewTheStartGot() async throws {
        let api = loadingAPI()
        api.startPendingReviewHandler = { _, _ in "PRR_7" }
        let store = LocalStore.inMemory()
        let cache = PullRequestCache(store: store)
        let engine = makeEngine(api: api, cache: cache, store: store)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))

        let start = cache.add(.startReview(pullRequestID: "node-1", commitID: "sha-1", reviewID: nil), to: reference(1))
        cache.add(.reviewComment(.reply(body: "One", threadID: "T"), review: .startedBy(start.id), authorLogin: nil),
                  to: reference(1))
        cache.add(.submitPendingReview(review: .startedBy(start.id), event: .approve, body: "", authorLogin: nil),
                  to: reference(1))
        var startedFrame: [PendingChange.Kind]?
        let subscription = cache.detailUpdates.sink { [unowned self] _ in
            let changes = cache.pendingChanges(for: reference(1))
            if startedFrame == nil, case .startReview(_, _, "PRR_7")? = changes.first?.kind {
                startedFrame = changes.map(\.kind)
            }
        }
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        subscription.cancel()

        XCTAssertEqual(api.startPendingReviewCalls.map(\.pullRequestID), ["node-1"])
        XCTAssertEqual(api.startPendingReviewCalls.map(\.commitID), ["sha-1"])
        XCTAssertEqual(api.pendingCommentCalls.map(\.reviewID), ["PRR_7"])
        XCTAssertEqual(api.submitPendingReviewCalls.map(\.reviewID), ["PRR_7"])
        XCTAssertEqual(startedFrame?.dropFirst().map(\.reviewTarget), [.review(id: "PRR_7"), .review(id: "PRR_7")],
                       "The later changes get the review's ID as soon as it starts")
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        await cache.saveNow()
        let saved = await store.pendingChanges()
        XCTAssertTrue(saved.isEmpty)
    }

    func testAFailedStartFailsTheChangesWaitingForItWithoutSendingThem() async throws {
        let api = loadingAPI()
        api.startPendingReviewHandler = { _, _ in throw GraphQLError(message: "One pending review per pull request") }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))

        let start = cache.add(.startReview(pullRequestID: "node-1", commitID: "sha-1", reviewID: nil), to: reference(1))
        cache.add(.reviewComment(.reply(body: "One", threadID: "T"), review: .startedBy(start.id), authorLogin: nil),
                  to: reference(1))
        cache.add(.discardPendingReview(review: .startedBy(start.id)), to: reference(1))
        cache.add(.title("Unrelated"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertTrue(api.pendingCommentCalls.isEmpty)
        XCTAssertTrue(api.deletePendingReviewCalls.isEmpty)
        XCTAssertEqual(api.editCalls.map(\.title), ["Unrelated"], "Other changes still send")
        let changes = cache.pendingChanges(for: reference(1))
        XCTAssertEqual(changes.map(\.state), [.failed, .failed, .failed])
        XCTAssertEqual(changes.map(\.error), [
            "One pending review per pull request",
            "Not sent — GitHub didn't start your pending review. One pending review per pull request",
            "Not sent — GitHub didn't start your pending review. One pending review per pull request",
        ])
    }

    func testADraftAndASubmittedReviewShowOnceThroughTheConfirmingReload() async throws {
        let api = loadingAPI()
        let date = Date(timeIntervalSince1970: 0)
        var github = PullRequestComments(comments: [], threads: [], pendingReviewID: "PRR_1")
        api.commentsHandler = { _, _ in github }
        api.pendingCommentHandler = { comment, _ in
            let draft = PullRequestComment(id: "RC_9", databaseID: 9, authorLogin: "monalisa", body: comment.body,
                                           createdAt: date, htmlURL: nil, isPending: true)
            github = github.adding(ReviewThread(id: "RT_9", path: "a.swift", line: 4, startLine: nil, side: .right,
                                                isResolved: false, isOutdated: false, comments: [draft]))
            return 9
        }
        api.submitPendingReviewHandler = { _, event, body in
            github = github.publishingPendingReview()
                .adding(review: PullRequestComment(id: "PRR_1", databaseID: 80, authorLogin: "monalisa", body: body,
                                                   createdAt: date, htmlURL: nil, reviewState: event.reviewerState))
            return 80
        }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))
        var frames: [(drafts: Int, reviews: Int)] = []
        let subscription = cache.detailUpdates.sink { entry in
            let comments = entry.1.comments
            frames.append((comments?.threads.flatMap(\.comments).count ?? 0, comments?.reviews.count ?? 0))
        }

        let anchor = DiffCommentAnchor(path: "a.swift", line: 4, side: .right)
        cache.add(.reviewComment(.thread(body: "Why?", anchor: anchor), review: .review(id: "PRR_1"),
                                 authorLogin: "monalisa"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        cache.add(.submitPendingReview(review: .review(id: "PRR_1"), event: .approve, body: "LGTM",
                                       authorLogin: "monalisa"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        subscription.cancel()

        XCTAssertFalse(frames.isEmpty)
        XCTAssertEqual(Set(frames.map(\.drafts)), [1], "The draft shows from the moment it's added, and never twice")
        XCTAssertEqual(frames.first?.reviews, 0)
        XCTAssertEqual(Set(frames.drop(while: { $0.reviews == 0 }).map(\.reviews)), [1], "The review never shows twice")
        let shown = try XCTUnwrap(cache.shownEntry(for: reference(1))?.comments)
        XCTAssertEqual(shown.reviews.map(\.id), ["PRR_1"])
        XCTAssertEqual(shown.threads.flatMap(\.comments).map(\.isPending), [false])
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        XCTAssertEqual(api.detailCalls.count, 2, "A submitted review reloads the reviewers too")
        XCTAssertEqual(api.fetchReviewRequestsTokens, ["token"], "And To Review, which it answers")
    }

    func testReviewsLeftByTheLastRunFailButADiscardIsSentAgain() async throws {
        let api = loadingAPI()
        let store = LocalStore.inMemory()
        let lastRun = PullRequestCache(store: store)
        await lastRun.waitForRestore()
        let review = lastRun.add(.review(NewPullRequestReview(event: .approve, body: "", commitID: "sha-1"),
                                         authorLogin: nil), to: reference(1))
        let start = lastRun.add(.startReview(pullRequestID: "node-1", commitID: "sha-1", reviewID: nil),
                                to: reference(1))
        lastRun.markSending(start.id)
        let draft = lastRun.add(.reviewComment(.reply(body: "Hi", threadID: "T"), review: .startedBy(start.id),
                                               authorLogin: nil), to: reference(1))
        let submit = lastRun.add(.submitPendingReview(review: .review(id: "PRR_1"), event: .comment, body: "Done",
                                                      authorLogin: nil), to: reference(1))
        lastRun.markSending(submit.id)
        let started = lastRun.add(.startReview(pullRequestID: "node-2", commitID: "sha-2", reviewID: nil),
                                  to: reference(2))
        let startedDraft = lastRun.add(.reviewComment(.reply(body: "Kept", threadID: "T"),
                                                      review: .startedBy(started.id), authorLogin: nil),
                                       to: reference(2))
        lastRun.markSending(started.id)
        lastRun.markStarted(started.id, reviewID: "PRR_2")
        let discard = lastRun.add(.discardPendingReview(review: .review(id: "PRR_3")), to: reference(3))
        lastRun.markSending(discard.id)
        await lastRun.saveNow()

        let cache = PullRequestCache(store: store)
        let engine = makeEngine(api: api, cache: cache, store: store)
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertTrue(api.reviewCalls.isEmpty, "A review may have posted, so it's never sent again on its own")
        XCTAssertTrue(api.startPendingReviewCalls.isEmpty)
        XCTAssertTrue(api.pendingCommentCalls.isEmpty)
        XCTAssertTrue(api.submitPendingReviewCalls.isEmpty)
        XCTAssertEqual(api.deletePendingReviewCalls.map(\.reviewID), ["PRR_3"], "Discarding twice is harmless")
        let changes = cache.pendingChanges(for: reference(1))
        XCTAssertEqual(changes.map(\.id), [review.id, start.id, draft.id, submit.id])
        XCTAssertEqual(Set(changes.map(\.state)), [.failed])
        XCTAssertEqual(Set(changes.map(\.error)), [PendingChange.notSentAfterQuitError])
        let second = cache.pendingChanges(for: reference(2))
        XCTAssertEqual(second.map(\.id), [startedDraft.id], "A review GitHub started is dropped; its draft keeps its ID")
        XCTAssertEqual(second.first?.kind.reviewTarget, .review(id: "PRR_2"))
        XCTAssertEqual(second.first?.state, .failed)
        XCTAssertTrue(cache.pendingChanges(for: reference(3)).isEmpty)
    }

    func testAReviewThatMayHaveReachedGitHubFailsAndReloadsWithoutBeingSentAgain() async throws {
        let api = loadingAPI()
        api.reviewHandler = { _, _ in throw URLError(.timedOut) }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))

        cache.add(.review(NewPullRequestReview(event: .approve, body: "", commitID: "sha-1"), authorLogin: nil),
                  to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(api.reviewCalls.count, 1)
        let failed = try XCTUnwrap(cache.pendingChanges(for: reference(1)).first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(failed.error?.hasSuffix("GitHub may have submitted it anyway, so check before you retry.") == true,
                      failed.error ?? "")
        XCTAssertEqual(api.detailCalls.count, 2, "Reloads the reviewers")
        XCTAssertEqual(api.commentsCalls.count, 2, "And the Activity list, so a review GitHub did take shows")
    }

    func testAStartThatMayHaveReachedGitHubSaysSo() async throws {
        let api = loadingAPI()
        api.startPendingReviewHandler = { _, _ in throw URLError(.networkConnectionLost) }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))

        cache.add(.startReview(pullRequestID: "node-1", commitID: "sha-1", reviewID: nil), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertTrue(cache.pendingChanges(for: reference(1)).first?.error?
                        .hasSuffix("GitHub may have started the review anyway, so check before you retry.") == true)
        XCTAssertEqual(api.commentsCalls.count, 2, "Reloads, so a review GitHub did start shows")
    }

    func testDiscardingAReviewThatIsAlreadyGoneCountsAsDone() async throws {
        let api = loadingAPI()
        var error: Error = GraphQLError(message: "Could not resolve to a node", type: "NOT_FOUND")
        api.deletePendingReviewHandler = { _ in throw error }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))

        cache.add(.discardPendingReview(review: .review(id: "PRR_1")), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)

        error = GraphQLError(message: "Forbidden", type: "FORBIDDEN")
        cache.add(.discardPendingReview(review: .review(id: "PRR_1")), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.error), ["Forbidden"])
    }

    func testRetrySendsTheSameSubmitAgainAndDiscardDropsIt() async throws {
        let api = loadingAPI()
        var shouldFail = true
        api.submitPendingReviewHandler = { _, _, _ in
            if shouldFail { throw GraphQLError(message: "Refused") }
            return nil
        }
        let cache = PullRequestCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))

        let retried = cache.add(.submitPendingReview(review: .review(id: "PRR_1"), event: .approve, body: "A",
                                                     authorLogin: nil), to: reference(1))
        let discarded = cache.add(.submitPendingReview(review: .review(id: "PRR_1"), event: .comment, body: "B",
                                                       authorLogin: nil), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.state), [.failed, .failed])
        XCTAssertEqual(cache.shownEntry(for: reference(1))?.comments?.reviews.map(\.body), ["A", "B"],
                       "Failed reviews stay shown")

        shouldFail = false
        cache.markPending(retried.id)
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        cache.discard(discarded.id)

        XCTAssertEqual(api.submitPendingReviewCalls.map(\.body), ["A", "B", "A"])
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        XCTAssertEqual(cache.shownEntry(for: reference(1))?.comments?.reviews, [])
    }

    // MARK: - Helpers

    private func makeEngine(api: FakeGitHubAPI, cache: PullRequestCache,
                            store: LocalStore = .inMemory()) -> SyncEngine {
        SyncEngine(api: api, store: store, cache: cache,
                   credential: { [unowned self] in SyncEngine.Credential(token: "token", session: session) },
                   now: { [clock] in clock.now })
    }

    private func loadingAPI() -> FakeGitHubAPI {
        let api = FakeGitHubAPI()
        api.detailHandler = { reference in detailContent(for: reference, title: "PR \(reference.number)") }
        return api
    }

    private func reference(_ number: Int) -> PullRequestReference {
        PullRequestReference(repoFullName: "acme/widgets", number: number)
    }

    private func content(headSHA: String) -> PullRequestDetailContent {
        let fixture = detailContent(for: reference(1)).detail
        return PullRequestDetailContent(
            detail: PullRequestDetail(reference: fixture.reference, nodeID: fixture.nodeID, title: fixture.title,
                                      body: fixture.body, authorLogin: fixture.authorLogin, state: fixture.state,
                                      baseRef: fixture.baseRef, headRef: fixture.headRef, headSHA: headSHA,
                                      htmlURL: fixture.htmlURL, createdAt: fixture.createdAt,
                                      additions: 0, deletions: 0, changedFiles: 0, commits: 1),
            files: [])
    }
}

/// Records what each committed transaction changed, such as "insert pull_request".
private final class CommitObserver: TransactionObserver {
    private(set) var tables: [Set<String>] = []
    private var current: Set<String> = []

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }

    func databaseDidChange(with event: DatabaseEvent) {
        let kind: String
        switch event.kind {
        case .insert: kind = "insert"
        case .update: kind = "update"
        case .delete: kind = "delete"
        }
        current.insert("\(kind) \(event.tableName)")
    }

    func databaseDidCommit(_ db: Database) {
        tables.append(current)
        current = []
    }

    func databaseDidRollback(_ db: Database) {
        current = []
    }
}

/// The detail is saved into the pull request's row, which a list or status may have made already.
private func savesPullRequest(_ changes: Set<String>) -> Bool {
    changes.contains("insert pull_request") || changes.contains("update pull_request")
}
