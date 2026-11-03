import XCTest
@testable import GithubPanel

final class PullRequestStateTests: XCTestCase {
    func testOpenWhenNothingElseApplies() {
        XCTAssertEqual(PullRequestState(pullRequest()), .open)
    }

    func testConflictComesBeforeEverythingElse() {
        let pr = pullRequest(isDraft: true, isAutoMergeEnabled: true, mergeStateStatus: "DIRTY")

        XCTAssertEqual(PullRequestState(pr), .conflict)
    }

    func testDraftComesBeforeQueueAndAutoMerge() {
        XCTAssertEqual(PullRequestState(pullRequest(isDraft: true, isAutoMergeEnabled: true)), .draft)
    }

    func testQueueComesBeforeAutoMerge() {
        let pr = pullRequest(isAutoMergeEnabled: true, isInMergeQueue: true, mergeStateStatus: "QUEUED")

        XCTAssertEqual(PullRequestState(pr), .queued)
    }

    func testAutoMerge() {
        XCTAssertEqual(PullRequestState(pullRequest(isAutoMergeEnabled: true, mergeStateStatus: "BLOCKED")), .autoMerge)
    }

    func testOtherBlockersStayOpen() {
        // Being behind or blocked by rules shows on the merge button, not the state icon.
        for status in ["BEHIND", "BLOCKED", "UNKNOWN", "UNSTABLE"] {
            XCTAssertEqual(PullRequestState(pullRequest(mergeStateStatus: status)), .open, status)
        }
    }

    private func pullRequest(isDraft: Bool = false,
                             isAutoMergeEnabled: Bool = false,
                             isInMergeQueue: Bool = false,
                             mergeStateStatus: String = "CLEAN") -> PullRequestRow {
        PullRequestRow(id: "acme/widgets#1",
                       nodeID: "PR_node",
                       title: "Example PR",
                       number: 1,
                       repoFullName: "acme/widgets",
                       htmlURL: URL(string: "https://github.com/acme/widgets/pull/1")!,
                       headSHA: "abc123",
                       status: .success,
                       isDraft: isDraft,
                       isAutoMergeEnabled: isAutoMergeEnabled,
                       canEnableAutoMerge: false,
                       canDisableAutoMerge: false,
                       isMergeQueueEnabled: false,
                       isInMergeQueue: isInMergeQueue,
                       mergeStateStatus: mergeStateStatus,
                       updatedAt: Date(timeIntervalSince1970: 0))
    }
}
