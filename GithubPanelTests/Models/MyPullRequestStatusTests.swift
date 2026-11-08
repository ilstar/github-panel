import XCTest
@testable import GithubPanel

final class MyPullRequestStatusTests: XCTestCase {
    func testConflictNeedsYouEvenOnADraftWithAutoMerge() {
        let pr = row(number: 1, status: .pending, autoMerge: true, isDraft: true, mergeStateStatus: "DIRTY")

        XCTAssertEqual(MyPullRequestStatus(pr), status(.needsYou, "Merge conflict"))
    }

    func testFailedChecksNeedYouEvenOnADraft() {
        XCTAssertEqual(MyPullRequestStatus(row(number: 1, status: .failure, isDraft: true)), status(.needsYou, "Checks failed"))
        XCTAssertEqual(MyPullRequestStatus(row(number: 1, status: .error)), status(.needsYou, "Checks failed"))
    }

    func testDraftWithoutProblemsIsADraft() {
        var pr = row(number: 1, status: .pending, isDraft: true)
        pr.reviewStatus = PullRequestReviewStatus(changesRequestedBy: ["alex"])

        XCTAssertEqual(MyPullRequestStatus(pr), status(.drafts, "Draft"))
    }

    func testChangesRequestedNeedYouWhileChecksRun() {
        var pr = row(number: 1, status: .pending)
        pr.reviewStatus = PullRequestReviewStatus(decision: .changesRequested, changesRequestedBy: ["alex", "maria"])

        XCTAssertEqual(MyPullRequestStatus(pr), status(.needsYou, "Changes requested by alex and maria"))
    }

    func testBotChangesRequestedNeedYou() {
        var pr = row(number: 1, status: .success)
        pr.reviewStatus = PullRequestReviewStatus(changesRequestedBy: ["review-bot"], waitingOn: ["alex"])

        XCTAssertEqual(MyPullRequestStatus(pr, botReviewer: "review-bot").group, .needsYou)
    }

    func testMergeQueueIsMerging() {
        let pr = row(number: 1, status: .pending, inMergeQueue: true, mergeStateStatus: "QUEUED")

        XCTAssertEqual(MyPullRequestStatus(pr), status(.merging, "In the merge queue"))
    }

    func testPendingChecksAreBuilding() {
        var pr = row(number: 1, status: .pending, mergeStateStatus: "BLOCKED")
        pr.reviewStatus = PullRequestReviewStatus(waitingOn: ["alex"])

        XCTAssertEqual(MyPullRequestStatus(pr), status(.building, "Checks running"))
    }

    func testPendingChecksWithAutoMergeAreMerging() {
        let pr = row(number: 1, status: .pending, autoMerge: true, mergeStateStatus: "BLOCKED")

        XCTAssertEqual(MyPullRequestStatus(pr), status(.merging, "Auto-merge when checks pass"))
    }

    func testWaitingReviewersAreInReview() {
        var pr = row(number: 1, status: .success, mergeStateStatus: "BLOCKED")
        pr.reviewStatus = PullRequestReviewStatus(decision: .reviewRequired, waitingOn: ["alex", "maria", "ios", "web"])

        XCTAssertEqual(MyPullRequestStatus(pr), status(.inReview, "Waiting on alex, maria and 2 more"))
    }

    func testEnoughApprovalsIsReadyEvenWithReviewersLeft() {
        var pr = row(number: 1, status: .success)
        pr.reviewStatus = PullRequestReviewStatus(decision: .approved, approvedBy: ["alex"], waitingOn: ["maria"])

        XCTAssertEqual(MyPullRequestStatus(pr), status(.readyToMerge, "Approved by alex"))
    }

    func testRequiredReviewWithNobodyAskedNeedsYou() {
        var pr = row(number: 1, status: .success, mergeStateStatus: "BLOCKED")
        pr.reviewStatus = PullRequestReviewStatus(decision: .reviewRequired)

        XCTAssertEqual(MyPullRequestStatus(pr), status(.needsYou, "No reviewer requested"))
    }

    func testRequiredReviewWithSomeApprovalsNeedsAnother() {
        var pr = row(number: 1, status: .success, mergeStateStatus: "BLOCKED")
        pr.reviewStatus = PullRequestReviewStatus(decision: .reviewRequired, approvedBy: ["alex"])

        XCTAssertEqual(MyPullRequestStatus(pr), status(.needsYou, "Needs another approval"))
    }

    func testOnlyTheBotApprovingStillNeedsAPerson() {
        var pr = row(number: 1, status: .success, mergeStateStatus: "BLOCKED")
        pr.reviewStatus = PullRequestReviewStatus(decision: .approved, approvedBy: ["review-bot"])

        XCTAssertEqual(MyPullRequestStatus(pr, botReviewer: "review-bot"), status(.needsYou, "No reviewer requested"))
    }

    func testBotStillReviewingIsInReview() {
        var pr = row(number: 1, status: .success, mergeStateStatus: "BLOCKED")
        pr.reviewStatus = PullRequestReviewStatus(decision: .approved, approvedBy: ["alex"], waitingOn: ["review-bot"])

        XCTAssertEqual(MyPullRequestStatus(pr, botReviewer: "review-bot"), status(.inReview, "Waiting on review-bot"))
    }

    func testPassingAutoMergeIsMerging() {
        let pr = row(number: 1, status: .success, autoMerge: true, mergeStateStatus: "BLOCKED")

        XCTAssertEqual(MyPullRequestStatus(pr), status(.merging, "Auto-merge is on"))
    }

    func testCleanWithoutReviewsIsReady() {
        XCTAssertEqual(MyPullRequestStatus(row(number: 1, status: .noChecks)), status(.readyToMerge, "Ready to merge"))
    }

    func testBehindAndBlockedNeedYou() {
        XCTAssertEqual(MyPullRequestStatus(row(number: 1, status: .success, mergeStateStatus: "BEHIND")),
                       status(.needsYou, "Behind the base branch"))
        XCTAssertEqual(MyPullRequestStatus(row(number: 1, status: .success, mergeStateStatus: "BLOCKED")),
                       status(.needsYou, "Blocked by branch rules"))
    }

    func testUnknownMergeabilityIsBuilding() {
        XCTAssertEqual(MyPullRequestStatus(row(number: 1, status: .success, mergeStateStatus: "UNKNOWN")),
                       status(.building, "Checking mergeability"))
    }

    func testGroupsRunFromMostUrgent() {
        XCTAssertEqual(MyPullRequestGroup.allCases, [.needsYou, .readyToMerge, .building, .inReview, .merging, .drafts])
    }

    func testCollapsedGroupsStorageRoundTrips() {
        let groups: Set<MyPullRequestGroup> = [.merging, .needsYou]

        XCTAssertEqual(CollapsedGroupsStorage.encode(groups), "needsYou,merging")
        XCTAssertEqual(CollapsedGroupsStorage.decode(CollapsedGroupsStorage.encode(groups)), groups)
        XCTAssertEqual(CollapsedGroupsStorage.decode("nonsense,,drafts"), [.drafts])
    }

    private func status(_ group: MyPullRequestGroup, _ reason: String) -> MyPullRequestStatus {
        MyPullRequestStatus(group, reason)
    }
}
