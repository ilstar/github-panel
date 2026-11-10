import XCTest
@testable import GithubPanel

@MainActor
final class PullRequestReviewTests: XCTestCase {
    private let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)

    func testOnlyOpenPullRequestsByOthersCanBeReviewed() async {
        let cases: [(isViewerAuthor: Bool, state: PullRequestDetail.State, canReview: Bool)] = [
            (false, .open, true),
            (false, .draft, true),
            (true, .open, false),
            (false, .merged, false),
            (false, .closed, false)
        ]
        for testCase in cases {
            let content = detail(isViewerAuthor: testCase.isViewerAuthor, state: testCase.state)
            let viewModel = PullRequestDetailViewModel(reference: reference, fetch: { _ in content })
            XCTAssertFalse(viewModel.canReview, "Nothing is loaded yet")

            await viewModel.load()

            XCTAssertEqual(viewModel.canReview, testCase.canReview, "\(testCase)")
        }
    }

    func testSubmitReviewSendsTheTrimmedMessageAgainstTheLoadedCommit() async throws {
        var sent: [(NewPullRequestReview, PullRequestReference)] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detail() },
                                                   submitReview: { review, reference in
                                                       sent.append((review, reference))
                                                       return 80
                                                   })
        await viewModel.load()

        viewModel.submitReview(.requestChanges, body: "  Please add tests.\n")
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(sent.map(\.0), [NewPullRequestReview(event: .requestChanges, body: "Please add tests.", commitID: "abc123")])
        XCTAssertEqual(sent.map(\.1), [reference])
        XCTAssertEqual(viewModel.submittedReview, .requestChanges)
    }

    func testASubmittedReviewShowsRightAwayInTheActivityListAndReviewers() async throws {
        let gate = Gate()
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detail(reviewers: [
                                                       PullRequestReviewer(name: "monalisa", kind: .user, state: .pending)
                                                   ]) },
                                                   submitReview: { _, _ in
                                                       await gate.wait()
                                                       return 80
                                                   },
                                                   viewerLogin: "monalisa")
        await viewModel.load()

        viewModel.submitReview(.approve, body: "Ship it")

        XCTAssertEqual(viewModel.submittedReview, .approve, "The verdict shows before GitHub answers")
        let shown = try XCTUnwrap(viewModel.comments?.timeline.last)
        XCTAssertEqual(shown.authorLogin, "monalisa")
        XCTAssertEqual(shown.body, "Ship it")
        XCTAssertEqual(shown.reviewState, .approved)
        XCTAssertEqual(viewModel.status(of: shown)?.isSaving, true, "Marked as sending")
        XCTAssertEqual(viewModel.content?.detail.reviewers.reviewers.map(\.state), [.approved],
                       "The review answers the viewer's request")

        await gate.open()
        await viewModel.waitForPendingChanges()
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
        XCTAssertEqual(viewModel.submittedReview, .approve)
    }

    func testApprovalNeedsNoMessageButOtherVerdictsDo() async throws {
        var sent: [NewPullRequestReview] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detail() },
                                                   submitReview: { review, _ in
                                                       sent.append(review)
                                                       return sent.count
                                                   })
        await viewModel.load()

        viewModel.submitReview(.comment, body: " ")
        viewModel.submitReview(.requestChanges, body: "")
        await viewModel.waitForPendingChanges()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(viewModel.submittedReview)

        viewModel.submitReview(.approve, body: "")
        await viewModel.waitForPendingChanges()
        XCTAssertEqual(sent.map(\.event), [.approve])
        XCTAssertEqual(viewModel.submittedReview, .approve)

        XCTAssertTrue(ReviewComposer.canSubmit(.approve, text: ""))
        XCTAssertFalse(ReviewComposer.canSubmit(.comment, text: " \n"))
        XCTAssertTrue(ReviewComposer.canSubmit(.requestChanges, text: "Fix it"))
    }

    func testOwnPullRequestIsNotSubmitted() async throws {
        var sent: [NewPullRequestReview] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detail(isViewerAuthor: true) },
                                                   submitReview: { review, _ in
                                                       sent.append(review)
                                                       return 1
                                                   })
        await viewModel.load()

        viewModel.submitReview(.approve, body: "")
        await viewModel.waitForPendingChanges()

        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
    }

    func testARefusedReviewStaysFailedWithItsTextUntilRetriedOrDiscarded() async throws {
        var shouldFail = true
        var sent: [NewPullRequestReview] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detail() },
                                                   submitReview: { review, _ in
                                                       sent.append(review)
                                                       if shouldFail { throw TestError(message: "Can not approve") }
                                                       return 80
                                                   })
        await viewModel.load()

        viewModel.submitReview(.approve, body: "Looks good")
        await viewModel.waitForPendingChanges()

        XCTAssertNil(viewModel.submittedReview, "A refused review isn't confirmed")
        let failed = try XCTUnwrap(viewModel.comments?.timeline.last)
        let status = try XCTUnwrap(viewModel.status(of: failed))
        XCTAssertEqual(status.failure, "Can not approve")
        XCTAssertEqual(status.text, "Looks good", "Copy offers the message")

        shouldFail = false
        status.retry()
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last, sent.first, "Retry sends the same review")
        XCTAssertEqual(viewModel.submittedReview, .approve)
        XCTAssertTrue(viewModel.pendingChanges.isEmpty)

        shouldFail = true
        viewModel.submitReview(.approve, body: "Again")
        await viewModel.waitForPendingChanges()
        let again = try XCTUnwrap(viewModel.pendingChanges.first)
        viewModel.discard(again)

        XCTAssertTrue(viewModel.pendingChanges.isEmpty)
        XCTAssertNil(viewModel.submittedReview)
        XCTAssertFalse(viewModel.comments?.timeline.contains { $0.body == "Again" } ?? true)
    }

    func testMonitorSubmitsWithSessionTokenAndRefreshesToReview() async throws {
        let api = FakeGitHubAPI()
        api.detailHandler = { [self] _ in detail() }
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 8)], fromMyTeams: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let viewModel = PullRequestDetailViewModel(reference: reference, monitor: monitor)
        await viewModel.load()

        viewModel.submitReview(.approve, body: "")
        await viewModel.waitForPendingChanges()

        XCTAssertEqual(api.reviewCalls.map(\.token), ["token"])
        XCTAssertEqual(api.reviewCalls.map(\.review), [NewPullRequestReview(event: .approve, body: "", commitID: "abc123")])
        XCTAssertEqual(api.fetchReviewRequestsTokens, ["token"], "Submitting answers the review request")
        XCTAssertEqual(monitor.reviewRequests.rows.map(\.number), [8])
    }

    func testMonitorReviewWithoutTokenWaits() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))
        api.detailHandler = { [self] _ in detail() }
        monitor.cache.store(detail())
        let viewModel = PullRequestDetailViewModel(reference: reference, monitor: monitor)

        viewModel.submitReview(.approve, body: "")
        await viewModel.waitForPendingChanges()

        XCTAssertTrue(api.reviewCalls.isEmpty)
        XCTAssertEqual(viewModel.pendingChanges.map(\.state), [.pending])
    }

    private func detail(isViewerAuthor: Bool = false, state: PullRequestDetail.State = .open,
                        reviewers: [PullRequestReviewer] = []) -> PullRequestDetailContent {
        PullRequestDetailContent(
            detail: PullRequestDetail(reference: reference,
                                      nodeID: "PR_node",
                                      title: "Add tests",
                                      body: "",
                                      authorLogin: "octocat",
                                      state: state,
                                      baseRef: "main",
                                      headRef: "feature",
                                      headSHA: "abc123",
                                      htmlURL: URL(string: "https://github.com/acme/widgets/pull/7")!,
                                      createdAt: Date(timeIntervalSince1970: 0),
                                      additions: 0,
                                      deletions: 0,
                                      changedFiles: 0,
                                      commits: 1,
                                      isViewerAuthor: isViewerAuthor,
                                      reviewers: PullRequestReviewers(reviewers: reviewers)),
            files: []
        )
    }
}
