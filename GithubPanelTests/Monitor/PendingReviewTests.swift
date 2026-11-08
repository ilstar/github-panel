import XCTest
@testable import GithubPanel

@MainActor
final class PendingReviewTests: XCTestCase {
    private let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)
    private let anchor = DiffCommentAnchor(path: "Sources/New.swift", line: 4, side: .right)

    func testFirstDraftStartsAReviewOnTheLoadedCommitThenAddsTheComment() async throws {
        let recorder = Recorder()
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()
        XCTAssertNil(viewModel.pendingReviewID)

        viewModel.addToReview(.thread(body: "Why?", anchor: anchor))

        // The draft shows right away on its line, marked as pending and sending.
        XCTAssertTrue(viewModel.isReviewPending)
        let shown = try XCTUnwrap(viewModel.threadIndex(for: anchor.path).threads(at: anchor).first?.comments.first)
        XCTAssertEqual(shown.body, "Why?")
        XCTAssertTrue(shown.isPending)
        XCTAssertEqual(viewModel.status(of: shown)?.isSaving, true)
        XCTAssertEqual(viewModel.pendingCommentCount, 1)

        await viewModel.waitForPendingChanges()

        XCTAssertEqual(recorder.started.map(\.pullRequestID), ["PR_node"])
        XCTAssertEqual(recorder.started.map(\.commitID), ["abc123"])
        XCTAssertEqual(recorder.drafts.map(\.reviewID), ["PRR_1"])
        XCTAssertEqual(recorder.drafts.map(\.comment), [.thread(body: "Why?", anchor: anchor)])
        XCTAssertTrue(recorder.posted.isEmpty, "A draft must not post right away")
        XCTAssertEqual(viewModel.pendingReviewID, "PRR_1")
        XCTAssertEqual(viewModel.pendingCommentCount, 1, "GitHub's copy shows instead, once")
        XCTAssertTrue(viewModel.isReviewPending)
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
    }

    func testLaterDraftsJoinThePendingReview() async throws {
        let recorder = Recorder()
        recorder.pendingReviewID = "PRR_existing"
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()
        let thread = try XCTUnwrap(viewModel.comments?.threads.first)

        viewModel.postInlineComment("Also here", at: anchor)
        viewModel.reply("Agreed", to: thread)

        let reply = try XCTUnwrap(viewModel.comments?.threads.first?.comments.last)
        XCTAssertEqual(reply.body, "Agreed", "The reply shows right away at the end of its thread")
        XCTAssertTrue(reply.isPending)

        await viewModel.waitForPendingChanges()

        XCTAssertTrue(recorder.started.isEmpty)
        XCTAssertTrue(recorder.posted.isEmpty, "Once a review is started, comments join it like on GitHub")
        XCTAssertEqual(recorder.drafts.map(\.reviewID), ["PRR_existing", "PRR_existing"])
        XCTAssertEqual(recorder.drafts.map(\.comment), [.thread(body: "Also here", anchor: anchor),
                                                        .reply(body: "Agreed", threadID: thread.id)])
    }

    func testWithoutAPendingReviewCommentsStillPostRightAway() async throws {
        let recorder = Recorder()
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        viewModel.postInlineComment("Single", at: anchor)
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(recorder.posted, [.inline(body: "Single", commitID: "abc123", anchor: anchor)])
        XCTAssertTrue(recorder.drafts.isEmpty)
    }

    func testDraftsAddedBeforeTheReviewStartsAreSentToItInOrder() async throws {
        let recorder = Recorder()
        let gate = Gate()
        recorder.startGate = gate
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        viewModel.addToReview(.thread(body: "One", anchor: anchor))
        viewModel.addToReview(.thread(body: "Two", anchor: anchor))
        viewModel.submitReview(.comment, body: "Done")

        XCTAssertEqual(viewModel.pendingChanges.filter { if case .startReview = $0.kind { true } else { false } }.count, 1,
                       "Both drafts wait for the same start")
        XCTAssertEqual(viewModel.comments?.threads.flatMap(\.comments).filter { $0.body == "One" || $0.body == "Two" }
                        .map(\.isPending), [false, false], "Submitting shows the drafts published right away")

        await gate.open()
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(recorder.calls, ["start", "draft PRR_1", "draft PRR_1", "submit PRR_1"])
        XCTAssertEqual(recorder.started.count, 1)
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
        XCTAssertNil(viewModel.pendingReviewID)
    }

    func testAFailedReloadDoesNotStartASecondReview() async throws {
        let recorder = Recorder()
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()
        recorder.failReload = true

        viewModel.addToReview(.thread(body: "One", anchor: anchor))
        await viewModel.waitForPendingChanges()
        viewModel.addToReview(.thread(body: "Two", anchor: anchor))
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(recorder.started.count, 1)
        XCTAssertEqual(recorder.drafts.map(\.reviewID), ["PRR_1", "PRR_1"])
        XCTAssertEqual(viewModel.pendingReviewID, "PRR_1")
    }

    func testARefusedDraftStaysInPlaceWithItsTextUntilRetried() async throws {
        let recorder = Recorder()
        recorder.pendingReviewID = "PRR_existing"
        recorder.draftError = TestError(message: "Line is outside the diff")
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        viewModel.addToReview(.thread(body: "Why?", anchor: anchor))
        await viewModel.waitForPendingChanges()

        let shown = try XCTUnwrap(viewModel.threadIndex(for: anchor.path).threads(at: anchor).first?.comments.first)
        let status = try XCTUnwrap(viewModel.status(of: shown))
        XCTAssertEqual(status.failure, "Line is outside the diff")
        XCTAssertEqual(status.text, "Why?")

        recorder.draftError = nil
        status.retry()
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(recorder.drafts.map(\.comment), [.thread(body: "Why?", anchor: anchor)])
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
    }

    func testAFailedStartFailsTheDraftsWaitingForItAndRetryStartsItAgain() async throws {
        let recorder = Recorder()
        recorder.startError = TestError(message: "Could not start")
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        viewModel.addToReview(.thread(body: "One", anchor: anchor))
        viewModel.addToReview(.thread(body: "Two", anchor: anchor))
        await viewModel.waitForPendingChanges()

        XCTAssertTrue(recorder.drafts.isEmpty, "Drafts aren't sent without their review")
        XCTAssertEqual(viewModel.pendingChanges.map(\.state), [.failed, .failed, .failed])
        let drafts = viewModel.comments?.threads.flatMap(\.comments).filter(\.isPending) ?? []
        XCTAssertEqual(drafts.map(\.body), ["One", "Two"], "They stay shown")
        XCTAssertEqual(drafts.compactMap { viewModel.status(of: $0)?.failure },
                       Array(repeating: "Not sent — GitHub didn't start your pending review. Could not start", count: 2))
        XCTAssertFalse(viewModel.isReviewPending, "A new draft starts a new review")

        recorder.startError = nil
        viewModel.status(of: drafts[0])?.retry()
        await viewModel.waitForPendingChanges()
        XCTAssertEqual(recorder.started.count, 1)
        XCTAssertEqual(recorder.drafts.map(\.comment.body), ["One"])

        // GitHub has the review now, so the other draft joins it.
        viewModel.retry(try XCTUnwrap(viewModel.pendingChanges.first))
        await viewModel.waitForPendingChanges()
        XCTAssertEqual(recorder.started.count, 1)
        XCTAssertEqual(recorder.drafts.map(\.reviewID), ["PRR_1", "PRR_1"])
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
    }

    func testDiscardingADraftWhoseReviewDidNotStartDropsTheStart() async throws {
        let recorder = Recorder()
        recorder.startError = TestError(message: "Could not start")
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        viewModel.addToReview(.thread(body: "One", anchor: anchor))
        await viewModel.waitForPendingChanges()
        let draft = try XCTUnwrap(viewModel.pendingChanges.last)
        viewModel.discard(draft)

        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
        XCTAssertEqual(viewModel.pendingCommentCount, 0)
    }

    func testOwnPullRequestCannotStartAReview() async throws {
        let recorder = Recorder()
        let viewModel = makeViewModel(recorder: recorder, isViewerAuthor: true)
        await viewModel.load()

        viewModel.addToReview(.thread(body: "Note", anchor: anchor))
        await viewModel.waitForPendingChanges()

        XCTAssertTrue(recorder.started.isEmpty)
        XCTAssertTrue(recorder.drafts.isEmpty)
    }

    func testSubmitPublishesThePendingReviewWithTheVerdict() async throws {
        let recorder = Recorder()
        recorder.pendingReviewID = "PRR_existing"
        recorder.drafts = [(.thread(body: "Why?", anchor: anchor), "PRR_existing")]
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()
        XCTAssertEqual(viewModel.pendingCommentCount, 1)

        // The drafts say enough, so a comment or change request needs no message.
        viewModel.submitReview(.requestChanges, body: "  ")

        XCTAssertEqual(viewModel.submittedReview, .requestChanges, "Shows right away")
        XCTAssertNil(viewModel.pendingReviewID)
        XCTAssertEqual(viewModel.pendingCommentCount, 0, "The drafts show as published")
        XCTAssertEqual(viewModel.comments?.timeline.last?.reviewState, .changesRequested)
        XCTAssertEqual(viewModel.comments?.timeline.last?.authorLogin, "me")

        await viewModel.waitForPendingChanges()

        XCTAssertEqual(recorder.submittedPending.map(\.reviewID), ["PRR_existing"])
        XCTAssertEqual(recorder.submittedPending.map(\.event), [.requestChanges])
        XCTAssertEqual(recorder.submittedPending.map(\.body), [""])
        XCTAssertTrue(recorder.reviews.isEmpty, "A second review must not be created next to the pending one")
        XCTAssertEqual(viewModel.submittedReview, .requestChanges)
        XCTAssertNil(viewModel.pendingReviewID)
        XCTAssertEqual(viewModel.pendingCommentCount, 0)
        XCTAssertEqual(viewModel.comments?.timeline.filter { $0.reviewState != nil }.count, 1,
                       "GitHub's copy of the review shows instead, once")
    }

    func testBlankMessageWithoutDraftsIsNotSubmitted() async throws {
        let recorder = Recorder()
        recorder.pendingReviewID = "PRR_existing"
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        viewModel.submitReview(.comment, body: " ")
        await viewModel.waitForPendingChanges()

        XCTAssertTrue(recorder.submittedPending.isEmpty)
        XCTAssertNil(viewModel.submittedReview)
    }

    func testDiscardHidesThePendingReviewRightAwayAndDeletesIt() async throws {
        let recorder = Recorder()
        recorder.pendingReviewID = "PRR_existing"
        recorder.drafts = [(.thread(body: "Why?", anchor: anchor), "PRR_existing")]
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        viewModel.discardPendingReview()

        XCTAssertNil(viewModel.pendingReviewID)
        XCTAssertFalse(viewModel.isReviewPending)
        XCTAssertEqual(viewModel.pendingCommentCount, 0)
        XCTAssertEqual(viewModel.comments?.threads.map(\.id), ["RT_1"], "The draft's thread goes too")

        await viewModel.waitForPendingChanges()

        XCTAssertEqual(recorder.deleted, ["PRR_existing"])
        XCTAssertNil(viewModel.pendingReviewID)
        XCTAssertNil(viewModel.submittedReview)
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
    }

    func testARefusedDiscardShowsWithRetryAndKeepsTheDraftsHidden() async throws {
        let recorder = Recorder()
        recorder.pendingReviewID = "PRR_existing"
        recorder.drafts = [(.thread(body: "Why?", anchor: anchor), "PRR_existing")]
        recorder.deleteError = TestError(message: "Forbidden")
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        viewModel.discardPendingReview()
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(viewModel.failedReviewDiscards.map(\.error), ["Forbidden"])
        XCTAssertEqual(viewModel.pendingCommentCount, 0)

        let failed = try XCTUnwrap(viewModel.failedReviewDiscards.first)
        viewModel.discard(failed)
        XCTAssertEqual(viewModel.pendingCommentCount, 1, "Discarding the change brings back what GitHub has")
    }

    func testDiscardingAReviewGitHubWasNotAskedToStartDropsItHere() async throws {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))
        monitor.detailCache.store(detail(isViewerAuthor: false))
        monitor.detailCache.store(PullRequestComments.empty, for: reference)
        let viewModel = PullRequestDetailViewModel(reference: reference, monitor: monitor)

        viewModel.addToReview(.thread(body: "Why?", anchor: anchor))
        await viewModel.waitForPendingChanges()
        XCTAssertEqual(viewModel.pendingChanges.map(\.state), [.pending, .pending], "Waits without a token")

        viewModel.discardPendingReview()
        await viewModel.waitForPendingChanges()

        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
        XCTAssertEqual(viewModel.pendingCommentCount, 0)
        XCTAssertTrue(api.startPendingReviewCalls.isEmpty)
        XCTAssertTrue(api.deletePendingReviewCalls.isEmpty)
    }

    func testReviewFormAllowsABlankMessageOnlyWithDrafts() {
        XCTAssertFalse(ReviewComposer.canSubmit(.comment, text: " ", pendingCommentCount: 0))
        XCTAssertTrue(ReviewComposer.canSubmit(.comment, text: " ", pendingCommentCount: 2))
        XCTAssertTrue(ReviewComposer.canSubmit(.requestChanges, text: "", pendingCommentCount: 1))
        XCTAssertEqual(ReviewComposer.pendingSummary(1), "1 pending comment will be published.")
        XCTAssertEqual(ReviewComposer.pendingSummary(3), "3 pending comments will be published.")
    }

    func testNewCommentModeFollowsTheReviewState() {
        XCTAssertEqual(PullRequestFilesView.newCommentMode(canReview: true, isReviewPending: false), .startReview)
        XCTAssertEqual(PullRequestFilesView.newCommentMode(canReview: true, isReviewPending: true), .addToReview)
        XCTAssertEqual(PullRequestFilesView.newCommentMode(canReview: false, isReviewPending: false), .single)
    }

    func testPendingCommentsAreCountedAndPendingThreadsAreMarked() {
        let date = Date(timeIntervalSince1970: 0)
        func comment(_ id: String, pending: Bool) -> PullRequestComment {
            PullRequestComment(id: id, databaseID: 1, authorLogin: "me", body: id, createdAt: date, htmlURL: nil, isPending: pending)
        }
        let draftThread = ReviewThread(id: "RT_1", path: "a.swift", line: 1, startLine: nil, side: .right,
                                       isResolved: false, isOutdated: false, comments: [comment("a", pending: true)])
        let mixedThread = ReviewThread(id: "RT_2", path: "a.swift", line: 2, startLine: nil, side: .right,
                                       isResolved: false, isOutdated: false,
                                       comments: [comment("b", pending: false), comment("c", pending: true)])
        let comments = PullRequestComments(comments: [], threads: [draftThread, mixedThread], pendingReviewID: "PRR")

        XCTAssertEqual(comments.pendingCommentCount, 2)
        XCTAssertTrue(draftThread.isPending)
        XCTAssertFalse(mixedThread.isPending, "A published thread with a draft reply can still be resolved")
    }

    func testMonitorSendsPendingReviewCallsWithSessionToken() async throws {
        let api = FakeGitHubAPI()
        api.detailHandler = { [self] _ in detail(isViewerAuthor: false) }
        var pendingReviewID: String?
        api.commentsHandler = { _, _ in PullRequestComments(comments: [], threads: [], pendingReviewID: pendingReviewID) }
        api.startPendingReviewHandler = { _, _ in
            pendingReviewID = "PRR_pending"
            return "PRR_pending"
        }
        api.submitPendingReviewHandler = { _, _, _ in
            pendingReviewID = nil
            return nil
        }
        api.deletePendingReviewHandler = { _ in pendingReviewID = nil }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let viewModel = PullRequestDetailViewModel(reference: reference, monitor: monitor)
        await viewModel.load()

        viewModel.addToReview(.reply(body: "Hi", threadID: "RT_1"))
        viewModel.submitReview(.approve, body: "")
        await viewModel.waitForPendingChanges()
        viewModel.addToReview(.reply(body: "Again", threadID: "RT_1"))
        await viewModel.waitForPendingChanges()
        viewModel.discardPendingReview()
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(api.startPendingReviewCalls.map(\.token), ["token", "token"])
        XCTAssertEqual(api.startPendingReviewCalls.map(\.commitID), ["abc123", "abc123"])
        XCTAssertEqual(api.pendingCommentCalls.map(\.reviewID), ["PRR_pending", "PRR_pending"])
        XCTAssertEqual(api.submitPendingReviewCalls.map(\.event), [.approve])
        XCTAssertEqual(api.deletePendingReviewCalls.map(\.reviewID), ["PRR_pending"])
        XCTAssertEqual(api.fetchReviewRequestsTokens, ["token"], "Submitting answers the review request")
    }

    // MARK: - Helpers

    /// Stands in for GitHub: keeps the pending review, its drafts and submitted reviews, and records every call.
    private final class Recorder {
        var pendingReviewID: String?
        var failReload = false
        var draftError: Error?
        var startError: Error?
        var deleteError: Error?
        var startGate: Gate?
        var started: [(pullRequestID: String, commitID: String)] = []
        var drafts: [(comment: PendingReviewComment, reviewID: String)] = []
        var submittedPending: [(reviewID: String, event: PullRequestReviewEvent, body: String)] = []
        var deleted: [String] = []
        var posted: [NewPullRequestComment] = []
        var reviews: [NewPullRequestReview] = []
        var calls: [String] = []
        /// Submitted reviews, as GitHub lists them.
        var submitted: [PullRequestComment] = []

        var comments: PullRequestComments {
            let date = Date(timeIntervalSince1970: 0)
            let published = PullRequestComment(id: "RC_1", databaseID: 21, authorLogin: "hubot", body: "Why?",
                                               createdAt: date, htmlURL: nil)
            var threads = [ReviewThread(id: "RT_1", path: "Sources/New.swift", line: 3, startLine: nil, side: .right,
                                        isResolved: false, isOutdated: false, comments: [published])]
            for (index, draft) in drafts.enumerated() where draft.reviewID == pendingReviewID {
                let comment = PullRequestComment(id: "draft-\(index)", databaseID: 100 + index, authorLogin: "me",
                                                 body: draft.comment.body, createdAt: date, htmlURL: nil, isPending: true)
                threads.append(ReviewThread(id: "RT_draft_\(index)", path: "Sources/New.swift", line: 4, startLine: nil,
                                            side: .right, isResolved: false, isOutdated: false, comments: [comment]))
            }
            return PullRequestComments(comments: [], threads: threads, pendingReviewID: pendingReviewID,
                                       reviews: submitted)
        }

        func submit(_ event: PullRequestReviewEvent, body: String) -> Int {
            let id = 500 + submitted.count
            submitted.append(PullRequestComment(id: "PRR_done_\(id)", databaseID: id, authorLogin: "me", body: body,
                                                createdAt: Date(), htmlURL: nil, reviewState: event.reviewerState))
            return id
        }
    }

    private func makeViewModel(recorder: Recorder, isViewerAuthor: Bool = false) -> PullRequestDetailViewModel {
        var loads = 0
        return PullRequestDetailViewModel(
            reference: reference,
            fetch: { [self] _ in detail(isViewerAuthor: isViewerAuthor) },
            fetchComments: { _, _ in
                loads += 1
                if recorder.failReload && loads > 1 { throw TestError(message: "Reload failed") }
                return recorder.comments
            },
            postComment: { comment, _ in
                recorder.posted.append(comment)
                return recorder.posted.count
            },
            submitReview: { review, _ in
                recorder.reviews.append(review)
                return recorder.submit(review.event, body: review.body)
            },
            startPendingReview: { pullRequestID, commitID in
                recorder.calls.append("start")
                await recorder.startGate?.wait()
                if let error = recorder.startError { throw error }
                recorder.started.append((pullRequestID, commitID))
                recorder.pendingReviewID = "PRR_\(recorder.started.count)"
                return "PRR_\(recorder.started.count)"
            },
            addPendingComment: { comment, reviewID in
                recorder.calls.append("draft \(reviewID)")
                if let error = recorder.draftError { throw error }
                recorder.drafts.append((comment, reviewID))
                return 100 + recorder.drafts.count - 1
            },
            submitPendingReview: { reviewID, event, body in
                recorder.calls.append("submit \(reviewID)")
                recorder.submittedPending.append((reviewID, event, body))
                recorder.pendingReviewID = nil
                recorder.drafts = []
                return recorder.submit(event, body: body)
            },
            deletePendingReview: { reviewID in
                if let error = recorder.deleteError { throw error }
                recorder.deleted.append(reviewID)
                recorder.pendingReviewID = nil
                recorder.drafts = []
            },
            viewerLogin: "me")
    }

    private func detail(isViewerAuthor: Bool) -> PullRequestDetailContent {
        PullRequestDetailContent(
            detail: PullRequestDetail(reference: reference,
                                      nodeID: "PR_node",
                                      title: "Add tests",
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
                                      commits: 1,
                                      isViewerAuthor: isViewerAuthor),
            files: []
        )
    }
}
