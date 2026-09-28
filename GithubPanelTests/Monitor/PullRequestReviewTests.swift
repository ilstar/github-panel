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
                                                   submitReview: { review, reference in sent.append((review, reference)) })
        await viewModel.load()

        try await viewModel.submitReview(.requestChanges, body: "  Please add tests.\n")

        XCTAssertEqual(sent.map(\.0), [NewPullRequestReview(event: .requestChanges, body: "Please add tests.", commitID: "abc123")])
        XCTAssertEqual(sent.map(\.1), [reference])
        XCTAssertEqual(viewModel.submittedReview, .requestChanges)
    }

    func testApprovalNeedsNoMessageButOtherVerdictsDo() async throws {
        var sent: [NewPullRequestReview] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detail() },
                                                   submitReview: { review, _ in sent.append(review) })
        await viewModel.load()

        try await viewModel.submitReview(.comment, body: " ")
        try await viewModel.submitReview(.requestChanges, body: "")
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(viewModel.submittedReview)

        try await viewModel.submitReview(.approve, body: "")
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
                                                   submitReview: { review, _ in sent.append(review) })
        await viewModel.load()

        try await viewModel.submitReview(.approve, body: "")

        XCTAssertTrue(sent.isEmpty)
    }

    func testRefusedReviewThrowsAndIsNotConfirmed() async {
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detail() },
                                                   submitReview: { _, _ in throw TestError(message: "Can not approve") })
        await viewModel.load()

        do {
            try await viewModel.submitReview(.approve, body: "")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Can not approve")
        }
        XCTAssertNil(viewModel.submittedReview)
    }

    func testMonitorSubmitsWithSessionTokenAndRefreshesToReview() async throws {
        let api = FakeGitHubAPI()
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 8)], fromMyTeams: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let review = NewPullRequestReview(event: .approve, body: "", commitID: "abc123")

        try await monitor.submitReview(review, on: reference)

        XCTAssertEqual(api.reviewCalls.map(\.token), ["token"])
        XCTAssertEqual(api.reviewCalls.map(\.review), [review])
        XCTAssertEqual(api.fetchReviewRequestsTokens, ["token"])
        XCTAssertEqual(monitor.reviewRequests.rows.map(\.number), [8])
    }

    func testMonitorReviewWithoutTokenFails() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))

        do {
            try await monitor.submitReview(NewPullRequestReview(event: .approve, body: "", commitID: "abc123"), on: reference)
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is MissingTokenError)
        }
        XCTAssertTrue(api.reviewCalls.isEmpty)
    }

    private func detail(isViewerAuthor: Bool = false, state: PullRequestDetail.State = .open) -> PullRequestDetailContent {
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
                                      isViewerAuthor: isViewerAuthor),
            files: []
        )
    }
}
