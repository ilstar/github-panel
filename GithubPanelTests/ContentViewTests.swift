import XCTest
@testable import GithubPanel

final class ContentViewTests: XCTestCase {
    func testRefreshTimelineOnlyUpdatesWhileAnimating() {
        XCTAssertFalse(RefreshAnimation.shouldUpdateTimeline(isLoading: false, isSettling: false))
        XCTAssertTrue(RefreshAnimation.shouldUpdateTimeline(isLoading: true, isSettling: false))
        XCTAssertTrue(RefreshAnimation.shouldUpdateTimeline(isLoading: false, isSettling: true))
    }

    func testRefreshAnimationCompletesItsCurrentCycle() {
        let firstCycle = RefreshAnimation.stopPlan(elapsed: 0.4)
        XCTAssertEqual(firstCycle.cycle, 1)
        XCTAssertEqual(firstCycle.delay, 1.2, accuracy: 0.000_001)

        let aligned = RefreshAnimation.stopPlan(elapsed: 1.6)
        XCTAssertEqual(aligned.cycle, 1)
        XCTAssertEqual(aligned.delay, 0, accuracy: 0.000_001)

        let secondCycle = RefreshAnimation.stopPlan(elapsed: 1.7)
        XCTAssertEqual(secondCycle.cycle, 2)
        XCTAssertEqual(secondCycle.delay, 1.5, accuracy: 0.000_001)
    }

    func testDraftPROffersMarkReadyAction() {
        let state = MergeButtonState.resolve(for: pullRequest(status: .pending, isDraft: true), isWorking: false)

        XCTAssertEqual(state, MergeButtonState.markReady)
        XCTAssertEqual(state.title, "Mark ready")
        XCTAssertTrue(state.isClickable)
    }

    func testReadyPRWithoutChecksOffersMergeOrQueueAction() {
        let mergeState = MergeButtonState.resolve(for: pullRequest(status: .noChecks), isWorking: false)
        let queueState = MergeButtonState.resolve(for: pullRequest(status: .noChecks, mergeQueueEnabled: true), isWorking: false)

        XCTAssertEqual(mergeState, MergeButtonState.merge)
        XCTAssertEqual(mergeState.title, "Merge")
        XCTAssertEqual(queueState, MergeButtonState.enqueue)
        XCTAssertEqual(queueState.title, "Add to queue")
        XCTAssertTrue(queueState.isClickable)
    }

    func testPRWithoutChecksDoesNotShowWaitingWhenOtherwiseBlocked() {
        let state = MergeButtonState.resolve(for: pullRequest(status: .noChecks, mergeStateStatus: "BLOCKED"), isWorking: false)

        XCTAssertEqual(state, MergeButtonState.blocked)
        XCTAssertNotEqual(state.title, "Waiting for checks")
    }

    private func pullRequest(status: CheckState,
                             isDraft: Bool = false,
                             mergeQueueEnabled: Bool = false,
                             mergeStateStatus: String = "CLEAN") -> PullRequestRow {
        PullRequestRow(id: "acme/widgets#1",
                       nodeID: "PR_node",
                       title: "Example PR",
                       number: 1,
                       repoFullName: "acme/widgets",
                       htmlURL: URL(string: "https://github.com/acme/widgets/pull/1")!,
                       headSHA: "abc123",
                       status: status,
                       isDraft: isDraft,
                       isAutoMergeEnabled: false,
                       canEnableAutoMerge: false,
                       canDisableAutoMerge: false,
                       isMergeQueueEnabled: mergeQueueEnabled,
                       isInMergeQueue: false,
                       mergeStateStatus: mergeStateStatus,
                       updatedAt: Date(timeIntervalSince1970: 0))
    }
}
