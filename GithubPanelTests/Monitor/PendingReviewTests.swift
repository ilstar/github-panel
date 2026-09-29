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

        try await viewModel.addToReview(.thread(body: "Why?", anchor: anchor))

        XCTAssertEqual(recorder.started.map(\.pullRequestID), ["PR_node"])
        XCTAssertEqual(recorder.started.map(\.commitID), ["abc123"])
        XCTAssertEqual(recorder.drafts.map(\.reviewID), ["PRR_1"])
        XCTAssertEqual(recorder.drafts.map(\.comment), [.thread(body: "Why?", anchor: anchor)])
        XCTAssertTrue(recorder.posted.isEmpty, "A draft must not post right away")
        XCTAssertEqual(viewModel.pendingReviewID, "PRR_1")
        XCTAssertEqual(viewModel.pendingCommentCount, 1)
        XCTAssertTrue(viewModel.isReviewPending)
    }

    func testLaterDraftsJoinThePendingReview() async throws {
        let recorder = Recorder()
        recorder.pendingReviewID = "PRR_existing"
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()
        let thread = try XCTUnwrap(viewModel.comments?.threads.first)

        try await viewModel.postInlineComment("Also here", at: anchor)
        try await viewModel.reply("Agreed", to: thread)

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

        try await viewModel.postInlineComment("Single", at: anchor)

        XCTAssertEqual(recorder.posted, [.inline(body: "Single", commitID: "abc123", anchor: anchor)])
        XCTAssertTrue(recorder.drafts.isEmpty)
    }

    func testAFailedReloadDoesNotStartASecondReview() async throws {
        let recorder = Recorder()
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()
        recorder.failReload = true

        try await viewModel.addToReview(.thread(body: "One", anchor: anchor))
        try await viewModel.addToReview(.thread(body: "Two", anchor: anchor))

        XCTAssertEqual(recorder.started.count, 1)
        XCTAssertEqual(recorder.drafts.map(\.reviewID), ["PRR_1", "PRR_1"])
        XCTAssertEqual(viewModel.errorMessage, "Reload failed")
    }

    func testRefusedDraftThrowsSoTheComposerKeepsIt() async {
        let recorder = Recorder()
        recorder.draftError = TestError(message: "Line is outside the diff")
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        do {
            try await viewModel.addToReview(.thread(body: "Why?", anchor: anchor))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Line is outside the diff")
        }
    }

    func testOwnPullRequestCannotStartAReview() async throws {
        let recorder = Recorder()
        let viewModel = makeViewModel(recorder: recorder, isViewerAuthor: true)
        await viewModel.load()

        try await viewModel.addToReview(.thread(body: "Note", anchor: anchor))

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
        try await viewModel.submitReview(.requestChanges, body: "  ")

        XCTAssertEqual(recorder.submittedPending.map(\.reviewID), ["PRR_existing"])
        XCTAssertEqual(recorder.submittedPending.map(\.event), [.requestChanges])
        XCTAssertEqual(recorder.submittedPending.map(\.body), [""])
        XCTAssertTrue(recorder.reviews.isEmpty, "A second review must not be created next to the pending one")
        XCTAssertEqual(viewModel.submittedReview, .requestChanges)
        XCTAssertNil(viewModel.pendingReviewID)
        XCTAssertEqual(viewModel.pendingCommentCount, 0)
    }

    func testBlankMessageWithoutDraftsIsNotSubmitted() async throws {
        let recorder = Recorder()
        recorder.pendingReviewID = "PRR_existing"
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        try await viewModel.submitReview(.comment, body: " ")

        XCTAssertTrue(recorder.submittedPending.isEmpty)
        XCTAssertNil(viewModel.submittedReview)
    }

    func testDiscardDeletesThePendingReview() async throws {
        let recorder = Recorder()
        recorder.pendingReviewID = "PRR_existing"
        let viewModel = makeViewModel(recorder: recorder)
        await viewModel.load()

        try await viewModel.discardPendingReview()

        XCTAssertEqual(recorder.deleted, ["PRR_existing"])
        XCTAssertNil(viewModel.pendingReviewID)
        XCTAssertNil(viewModel.submittedReview)
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
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        let reviewID = try await monitor.startPendingReview(pullRequestID: "PR_node", commitID: "abc123")
        try await monitor.addPendingReviewComment(.reply(body: "Hi", threadID: "RT_1"), reviewID: reviewID)
        try await monitor.submitPendingReview(reviewID: reviewID, event: .approve, body: "")
        try await monitor.deletePendingReview(reviewID: reviewID)

        XCTAssertEqual(api.startPendingReviewCalls.map(\.token), ["token"])
        XCTAssertEqual(api.startPendingReviewCalls.map(\.commitID), ["abc123"])
        XCTAssertEqual(api.pendingCommentCalls.map(\.reviewID), [reviewID])
        XCTAssertEqual(api.submitPendingReviewCalls.map(\.event), [.approve])
        XCTAssertEqual(api.deletePendingReviewCalls.map(\.reviewID), [reviewID])
        XCTAssertEqual(api.fetchReviewRequestsTokens, ["token"], "Submitting answers the review request")
    }

    // MARK: - Helpers

    /// Stands in for GitHub: keeps the pending review and its drafts, and records every call.
    private final class Recorder {
        var pendingReviewID: String?
        var failReload = false
        var draftError: Error?
        var started: [(pullRequestID: String, commitID: String)] = []
        var drafts: [(comment: PendingReviewComment, reviewID: String)] = []
        var submittedPending: [(reviewID: String, event: PullRequestReviewEvent, body: String)] = []
        var deleted: [String] = []
        var posted: [NewPullRequestComment] = []
        var reviews: [NewPullRequestReview] = []

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
            return PullRequestComments(comments: [], threads: threads, pendingReviewID: pendingReviewID)
        }
    }

    private func makeViewModel(recorder: Recorder, isViewerAuthor: Bool = false) -> PullRequestDetailViewModel {
        var loads = 0
        return PullRequestDetailViewModel(
            reference: reference,
            fetch: { [self] _ in detail(isViewerAuthor: isViewerAuthor) },
            fetchComments: { _ in
                loads += 1
                if recorder.failReload && loads > 1 { throw TestError(message: "Reload failed") }
                return recorder.comments
            },
            postComment: { comment, _ in recorder.posted.append(comment) },
            submitReview: { review, _ in recorder.reviews.append(review) },
            startPendingReview: { pullRequestID, commitID in
                recorder.started.append((pullRequestID, commitID))
                recorder.pendingReviewID = "PRR_\(recorder.started.count)"
                return "PRR_\(recorder.started.count)"
            },
            addPendingComment: { comment, reviewID in
                if let error = recorder.draftError { throw error }
                recorder.drafts.append((comment, reviewID))
            },
            submitPendingReview: { reviewID, event, body in
                recorder.submittedPending.append((reviewID, event, body))
                recorder.pendingReviewID = nil
                recorder.drafts = []
            },
            deletePendingReview: { reviewID in
                recorder.deleted.append(reviewID)
                recorder.pendingReviewID = nil
                recorder.drafts = []
            })
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
