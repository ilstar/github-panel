import XCTest
@testable import GithubPanel

final class PullRequestReviewStatusTests: XCTestCase {
    func testNoReviewsShowNoBadge() {
        XCTAssertNil(PullRequestReviewStatus.none.badge)
        XCTAssertNil(PullRequestReviewStatus.none.helpText)
    }

    func testChangesRequestedWinsOverApprovals() {
        let status = PullRequestReviewStatus(decision: .changesRequested,
                                             approvedBy: ["hubot"],
                                             changesRequestedBy: ["monalisa"])

        XCTAssertEqual(status.badge, .changesRequested)
        XCTAssertEqual(status.helpText, "Approved by hubot.\nChanges requested by monalisa.")
    }

    func testChangesRequestedShowsEvenWithoutRequiredReviews() {
        let status = PullRequestReviewStatus(decision: nil, approvedBy: ["hubot"], changesRequestedBy: ["monalisa"])

        XCTAssertEqual(status.badge, .changesRequested)
    }

    func testApprovalShowsWithOrWithoutRequiredReviews() {
        XCTAssertEqual(PullRequestReviewStatus(decision: .approved, approvedBy: ["octocat"]).badge, .approved)
        XCTAssertEqual(PullRequestReviewStatus(decision: nil, approvedBy: ["octocat"]).badge, .approved)
    }

    func testOneApprovalOfTwoRequiredIsStillWaiting() {
        let status = PullRequestReviewStatus(decision: .reviewRequired, approvedBy: ["octocat"], waitingOn: ["hubot"])

        XCTAssertEqual(status.badge, .awaitingReview)
        XCTAssertEqual(status.helpText, "Approved by octocat.\nWaiting on hubot.")
    }

    func testRequiredReviewWithNobodyAskedNeedsAReviewer() {
        let status = PullRequestReviewStatus(decision: .reviewRequired)

        XCTAssertEqual(status.badge, .needsReview)
        XCTAssertEqual(status.helpText, "The base branch needs an approving review. Ask someone to review it.")
    }

    func testPendingRequestsWithoutRequiredReviewsAreAwaitingReview() {
        let status = PullRequestReviewStatus(decision: nil, waitingOn: ["acme/web"])

        XCTAssertEqual(status.badge, .awaitingReview)
        XCTAssertEqual(status.helpText, "Waiting on acme/web.")
    }
}
