import XCTest
@testable import GithubPanel

final class PullRequestReviewStatusTests: XCTestCase {
    func testNoReviewsShowTheNeutralIndicator() {
        XCTAssertEqual(PullRequestReviewStatus.none.indicator, .none)
        XCTAssertNil(PullRequestReviewStatus.none.helpText)
    }

    func testChangesRequestedWinsOverApprovals() {
        let status = PullRequestReviewStatus(decision: .changesRequested,
                                             approvedBy: ["hubot"],
                                             changesRequestedBy: ["monalisa"])

        XCTAssertEqual(status.indicator, .changesRequested)
        XCTAssertEqual(status.helpText, "Approved by hubot.\nChanges requested by monalisa.")
    }

    func testChangesRequestedShowsEvenWithoutRequiredReviews() {
        let status = PullRequestReviewStatus(decision: nil, approvedBy: ["hubot"], changesRequestedBy: ["monalisa"])

        XCTAssertEqual(status.indicator, .changesRequested)
    }

    func testApprovalShowsWithOrWithoutRequiredReviews() {
        XCTAssertEqual(PullRequestReviewStatus(decision: .approved, approvedBy: ["octocat"]).indicator, .approved)
        XCTAssertEqual(PullRequestReviewStatus(decision: nil, approvedBy: ["octocat"]).indicator, .approved)
    }

    func testOneApprovalOfTwoRequiredIsStillWaiting() {
        let status = PullRequestReviewStatus(decision: .reviewRequired, approvedBy: ["octocat"], waitingOn: ["hubot"])

        XCTAssertEqual(status.indicator, .waiting)
        XCTAssertEqual(status.helpText, "Approved by octocat.\nWaiting on hubot.")
    }

    func testRequiredReviewWithNobodyAskedNeedsAReviewer() {
        let status = PullRequestReviewStatus(decision: .reviewRequired)

        XCTAssertEqual(status.indicator, .waiting)
        XCTAssertEqual(status.helpText, "The base branch needs an approving review. Ask someone to review it.")
    }

    func testPendingRequestsWithoutRequiredReviewsAreAwaitingReview() {
        let status = PullRequestReviewStatus(decision: nil, waitingOn: ["acme/web"])

        XCTAssertEqual(status.indicator, .waiting)
        XCTAssertEqual(status.helpText, "Waiting on acme/web.")
    }

    func testEnoughApprovalsIsApprovedWhileOthersAreStillAsked() {
        // GitHub's verdict decides: the required approvals are in, even though hubot has not answered.
        let status = PullRequestReviewStatus(decision: .approved, approvedBy: ["octocat"], waitingOn: ["hubot"])

        XCTAssertEqual(status.indicator, .approved)
    }

    func testGitHubsVerdictWinsOverAnOlderRequestForChanges() {
        let status = PullRequestReviewStatus(decision: .approved, approvedBy: ["octocat"], changesRequestedBy: ["hubot"])

        XCTAssertEqual(status.indicator, .approved)
    }
}
