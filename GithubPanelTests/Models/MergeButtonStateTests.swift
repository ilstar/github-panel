import XCTest
@testable import GithubPanel

final class MergeButtonStateTests: XCTestCase {
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

        XCTAssertEqual(state, MergeButtonState.blocked(.branchRules))
        XCTAssertNotEqual(state.title, "Waiting for checks")
    }

    func testBlockedButtonNamesTheReason() {
        let cases: [(mergeStateStatus: String, decision: ReviewDecision?, reason: MergeBlockReason, title: String)] = [
            ("DIRTY", nil, .conflicts, "Merge conflict"),
            ("BEHIND", nil, .behindBase, "Out of date"),
            ("BLOCKED", .changesRequested, .changesRequested, "Changes requested"),
            ("BLOCKED", .reviewRequired, .needsApproval, "Needs approval"),
            ("BLOCKED", .approved, .branchRules, "Blocked by rules"),
            ("BLOCKED", nil, .branchRules, "Blocked by rules"),
            ("UNKNOWN", nil, .checkingMergeability, "Checking merge"),
            ("UNSTABLE", nil, .other, "Not mergeable")
        ]

        for testCase in cases {
            let pr = pullRequest(status: .success,
                                 mergeStateStatus: testCase.mergeStateStatus,
                                 reviewStatus: PullRequestReviewStatus(decision: testCase.decision))
            let state = MergeButtonState.resolve(for: pr, isWorking: false)

            XCTAssertEqual(state, .blocked(testCase.reason), testCase.mergeStateStatus)
            XCTAssertEqual(state.title, testCase.title, testCase.mergeStateStatus)
            XCTAssertFalse(state.isClickable)
            XCTAssertEqual(state.helpText, testCase.reason.explanation)
        }
    }

    func testConflictShowsInsteadOfAutoMergeOrWaiting() {
        let canAutoMerge = pullRequest(status: .pending, canEnableAutoMerge: true, mergeStateStatus: "DIRTY")
        let waiting = pullRequest(status: .pending, mergeStateStatus: "DIRTY")

        XCTAssertEqual(MergeButtonState.resolve(for: canAutoMerge, isWorking: false), .blocked(.conflicts))
        XCTAssertEqual(MergeButtonState.resolve(for: waiting, isWorking: false), .blocked(.conflicts))
    }

    func testFailedChecksAndEnabledAutoMergeStillWinOverAConflict() {
        let failed = pullRequest(status: .failure, mergeStateStatus: "DIRTY")
        let autoMergeOn = pullRequest(status: .pending, isAutoMergeEnabled: true, mergeStateStatus: "DIRTY")

        XCTAssertEqual(MergeButtonState.resolve(for: failed, isWorking: false), .checksFailed)
        XCTAssertEqual(MergeButtonState.resolve(for: autoMergeOn, isWorking: false), .disableAutoMerge)
    }

    func testActionableButtonsHaveNoHelpText() {
        XCTAssertNil(MergeButtonState.merge.helpText)
        XCTAssertNil(MergeButtonState.enableAutoMerge.helpText)
        XCTAssertNotNil(MergeButtonState.checksFailed.helpText)
    }

    private func pullRequest(status: CheckState,
                             isDraft: Bool = false,
                             mergeQueueEnabled: Bool = false,
                             isAutoMergeEnabled: Bool = false,
                             canEnableAutoMerge: Bool = false,
                             mergeStateStatus: String = "CLEAN",
                             reviewStatus: PullRequestReviewStatus = .none) -> PullRequestRow {
        PullRequestRow(id: "acme/widgets#1",
                       nodeID: "PR_node",
                       title: "Example PR",
                       number: 1,
                       repoFullName: "acme/widgets",
                       htmlURL: URL(string: "https://github.com/acme/widgets/pull/1")!,
                       headSHA: "abc123",
                       status: status,
                       isDraft: isDraft,
                       isAutoMergeEnabled: isAutoMergeEnabled,
                       canEnableAutoMerge: canEnableAutoMerge,
                       canDisableAutoMerge: false,
                       isMergeQueueEnabled: mergeQueueEnabled,
                       isInMergeQueue: false,
                       mergeStateStatus: mergeStateStatus,
                       updatedAt: Date(timeIntervalSince1970: 0),
                       reviewStatus: reviewStatus)
    }
}
