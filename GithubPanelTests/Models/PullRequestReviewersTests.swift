import XCTest
@testable import GithubPanel

final class PullRequestReviewersTests: XCTestCase {
    private typealias Review = PullRequestReviewers.Review
    private typealias Request = PullRequestReviewers.Request

    func testListsRequestedAndReviewedUsersAndTeamsByName() {
        let reviewers = PullRequestReviewers(decision: .reviewRequired,
                                             reviews: [Review(author: "zed", state: "APPROVED"),
                                                       Review(author: "Bob", state: "COMMENTED")],
                                             requests: [Request(name: "acme/web", kind: .team, asCodeOwner: true),
                                                        Request(name: "carol", kind: .user)],
                                             authorLogin: "octocat")

        XCTAssertEqual(reviewers.reviewers, [
            PullRequestReviewer(name: "acme/web", kind: .team, state: .pending, isCodeOwner: true),
            PullRequestReviewer(name: "Bob", kind: .user, state: .commented),
            PullRequestReviewer(name: "carol", kind: .user, state: .pending),
            PullRequestReviewer(name: "zed", kind: .user, state: .approved)
        ])
    }

    func testReRequestedReviewerWaitsAndRemembersTheEarlierVerdict() {
        let reviewers = PullRequestReviewers(decision: .approved,
                                             reviews: [Review(author: "hubot", state: "APPROVED")],
                                             requests: [Request(name: "HUBOT", kind: .user)],
                                             authorLogin: "octocat")

        XCTAssertEqual(reviewers.reviewers, [
            PullRequestReviewer(name: "HUBOT", kind: .user, state: .pending, previousState: .approved)
        ])
        XCTAssertEqual(reviewers.reviewers[0].helpText,
                       "Awaiting requested review from HUBOT. HUBOT previously approved these changes")
    }

    func testTeamFulfilledOnItsBehalfShowsTheReviewerInstead() {
        let reviewers = PullRequestReviewers(decision: .reviewRequired,
                                             reviews: [Review(author: "hubot", state: "APPROVED", onBehalfOf: ["acme/ios"])],
                                             requests: [Request(name: "acme/web", kind: .team)],
                                             authorLogin: "octocat")

        XCTAssertEqual(reviewers.reviewers.map(\.name), ["acme/web", "hubot"])
        XCTAssertEqual(reviewers.reviewers[1].helpText, "hubot approved these changes on behalf of acme/ios")
    }

    func testLeavesOutTheAuthorAndPendingReviews() {
        let reviewers = PullRequestReviewers(decision: nil,
                                             reviews: [Review(author: "Octocat", state: "COMMENTED"),
                                                       Review(author: "hubot", state: "PENDING")],
                                             requests: [],
                                             authorLogin: "octocat")

        XCTAssertEqual(reviewers.reviewers, [])
        XCTAssertEqual(reviewers.summary.title, "No reviews")
        XCTAssertNil(reviewers.summary.tone)
    }

    func testSummaryFollowsGitHubsDecision() {
        func summary(_ decision: ReviewDecision?, _ states: [String], requests: [Request] = []) -> String {
            let reviews = states.enumerated().map { Review(author: "user\($0.offset)", state: $0.element) }
            let summary = PullRequestReviewers(decision: decision, reviews: reviews, requests: requests, authorLogin: "me").summary
            return [summary.title, summary.detail].compactMap { $0 }.joined(separator: " — ")
        }

        XCTAssertEqual(summary(.approved, ["APPROVED", "APPROVED"]), "Changes approved — 2 approving reviews")
        XCTAssertEqual(summary(.changesRequested, ["APPROVED", "CHANGES_REQUESTED"]),
                       "Changes requested — 1 review requesting changes")
        XCTAssertEqual(summary(.reviewRequired, []),
                       "Review required — At least 1 approving review is required by reviewers with write access.")
        XCTAssertEqual(summary(.reviewRequired, ["APPROVED"]),
                       "Review required — 1 approving review so far. More are required by reviewers with write access.")
        XCTAssertEqual(summary(nil, ["APPROVED"]), "Approved — 1 approving review")
        XCTAssertEqual(summary(nil, [], requests: [Request(name: "a", kind: .user), Request(name: "b/c", kind: .team)]),
                       "Awaiting review — 2 reviews requested")
    }

    func testStatusTooltipsMatchGitHub() {
        XCTAssertEqual(PullRequestReviewer(name: "acme/web", kind: .team, state: .pending).helpText,
                       "Awaiting requested review from acme/web")
        XCTAssertEqual(PullRequestReviewer(name: "a", kind: .user, state: .changesRequested).helpText, "a requested changes")
        XCTAssertEqual(PullRequestReviewer(name: "a", kind: .user, state: .commented).helpText, "a left review comments")
        XCTAssertEqual(PullRequestReviewer(name: "a", kind: .user, state: .dismissed).helpText, "a's review was dismissed")
    }
}
