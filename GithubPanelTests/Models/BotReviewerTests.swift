import XCTest
@testable import GithubPanel

final class BotReviewerTests: XCTestCase {
    func testNormalizesTheLoginTheWayGraphQLSpellsIt() {
        XCTAssertEqual(BotReviewer.normalized("  @Review-Bot[bot] "), "review-bot")
        XCTAssertEqual(BotReviewer.normalized("review-bot"), "review-bot")
        XCTAssertNil(BotReviewer.normalized("   "))
        XCTAssertNil(BotReviewer.normalized("@"))
    }

    func testBotIndicatorFollowsTheBotsReview() {
        XCTAssertEqual(PullRequestReviewStatus.none.botIndicator(for: "review-bot"), .none)
        XCTAssertEqual(PullRequestReviewStatus(waitingOn: ["Review-Bot"]).botIndicator(for: "review-bot"), .waiting)
        XCTAssertEqual(PullRequestReviewStatus(approvedBy: ["review-bot"]).botIndicator(for: "review-bot"), .approved)
        XCTAssertEqual(PullRequestReviewStatus(changesRequestedBy: ["review-bot"]).botIndicator(for: "review-bot"),
                       .changesRequested)
    }

    func testBotIndicatorIgnoresOtherReviewers() {
        let status = PullRequestReviewStatus(decision: .approved, approvedBy: ["octocat"], waitingOn: ["acme/web"])

        XCTAssertEqual(status.botIndicator(for: "review-bot"), .none)
    }

    func testRerequestedReviewIsWaitingEvenAfterAnEarlierVerdict() {
        let status = PullRequestReviewStatus(changesRequestedBy: ["review-bot"], waitingOn: ["review-bot"])

        XCTAssertEqual(status.botIndicator(for: "review-bot"), .waiting)
    }

    func testExcludingBotKeepsOnlyPeople() {
        let status = PullRequestReviewStatus(decision: .reviewRequired,
                                             approvedBy: ["review-bot"],
                                             waitingOn: ["octocat", "review-bot"])

        XCTAssertEqual(status.excludingBot("review-bot"),
                       PullRequestReviewStatus(decision: .reviewRequired, waitingOn: ["octocat"]))
    }

    func testBotOnlyApprovalNoLongerReadsAsApprovedByPeople() {
        let status = PullRequestReviewStatus(decision: .approved, approvedBy: ["review-bot"], waitingOn: ["octocat"])
        let people = status.excludingBot("review-bot")

        XCTAssertEqual(people.decision, .reviewRequired)
        XCTAssertEqual(people.indicator, .waiting)
    }

    func testBotOnlyChangeRequestNoLongerReadsAsChangesRequestedByPeople() {
        let status = PullRequestReviewStatus(decision: .changesRequested, changesRequestedBy: ["review-bot"])

        XCTAssertEqual(status.excludingBot("review-bot").indicator, .waiting)
    }

    func testPeoplesVerdictStaysWhenTheyGaveIt() {
        let status = PullRequestReviewStatus(decision: .approved, approvedBy: ["octocat", "review-bot"])

        XCTAssertEqual(status.excludingBot("review-bot"),
                       PullRequestReviewStatus(decision: .approved, approvedBy: ["octocat"]))
    }

    func testNoBotInvolvedLeavesStatusUnchanged() {
        let status = PullRequestReviewStatus(decision: nil, approvedBy: ["octocat"], changesRequestedBy: ["monalisa"])

        XCTAssertEqual(status.excludingBot("review-bot"), status)
    }
}
