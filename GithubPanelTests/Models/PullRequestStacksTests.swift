import XCTest
@testable import GithubPanel

final class PullRequestStacksTests: XCTestCase {
    func testGroupsAStackBottomFirstAtItsLatestUpdate() {
        // GitHub's order, newest first: #5 (top of the stack), #4, #3 (middle), #2, #1 (bottom).
        let rows = [
            stacked(5, base: "step-2", head: "step-3", updated: 50),
            stacked(4, base: "main", head: "other", updated: 40),
            stacked(3, base: "step-1", head: "step-2", updated: 30),
            stacked(2, base: "main", head: "lonely", updated: 20),
            stacked(1, base: "main", head: "step-1", updated: 10)
        ]

        let sections = MyPullRequestSections(rows: rows, forLaterIDs: [])

        XCTAssertEqual(sections.active.map(\.number), [1, 3, 5, 4, 2])
        XCTAssertEqual(sections.activeEntries.map(\.rows.count), [3, 1, 1])
        XCTAssertEqual(sections.stackPositions["acme/widgets#1"],
                       PullRequestStackPosition(stackID: "acme/widgets#1", number: 1, count: 3, basePullRequestNumber: nil))
        XCTAssertEqual(sections.stackPositions["acme/widgets#3"]?.label, "2/3")
        XCTAssertEqual(sections.stackPositions["acme/widgets#3"]?.basePullRequestNumber, 1)
        XCTAssertEqual(sections.stackPositions["acme/widgets#5"]?.label, "3/3")
        XCTAssertNil(sections.stackPositions["acme/widgets#4"])
        XCTAssertNil(sections.stackPositions["acme/widgets#2"])
    }

    func testStackSortsByItsNewestMemberEvenWhenTheBottomIsNewest() {
        let rows = [
            stacked(1, base: "main", head: "step-1", updated: 30),
            stacked(9, base: "main", head: "solo", updated: 20),
            stacked(2, base: "step-1", head: "step-2", updated: 10)
        ]

        XCTAssertEqual(MyPullRequestSections(rows: rows, forLaterIDs: []).active.map(\.number), [1, 2, 9])
    }

    func testBranchesOnlyStackWithinOneRepository() {
        let rows = [
            stacked(2, base: "feature", head: "next", updated: 20, repo: "acme/gadgets"),
            stacked(1, base: "main", head: "feature", updated: 10)
        ]

        XCTAssertTrue(PullRequestStacks.positions(in: rows).isEmpty)
    }

    func testPullRequestsWithoutBranchesAreNotStacked() {
        let rows = [row(number: 2, status: .success), row(number: 1, status: .success)]

        XCTAssertTrue(PullRequestStacks.positions(in: rows).isEmpty)
        XCTAssertEqual(MyPullRequestSections(rows: rows, forLaterIDs: []).active.map(\.number), [2, 1])
    }

    func testTwoPullRequestsOnOneBaseListOneBranchAfterTheOther() {
        let rows = [
            stacked(3, base: "step-1", head: "right", updated: 30),
            stacked(2, base: "step-1", head: "left", updated: 20),
            stacked(1, base: "main", head: "step-1", updated: 10)
        ]

        let positions = PullRequestStacks.positions(in: rows)

        XCTAssertEqual(MyPullRequestSections(rows: rows, forLaterIDs: []).active.map(\.number), [1, 3, 2])
        XCTAssertEqual(positions["acme/widgets#3"]?.basePullRequestNumber, 1)
        XCTAssertEqual(positions["acme/widgets#2"]?.basePullRequestNumber, 1)
        XCTAssertEqual(positions.values.map(\.count), [3, 3, 3])
    }

    func testBranchesBasedOnEachOtherInALoopStillGroupOnce() {
        let rows = [
            stacked(2, base: "a", head: "b", updated: 20),
            stacked(1, base: "b", head: "a", updated: 10)
        ]

        let entries = MyPullRequestSections(rows: rows, forLaterIDs: []).activeEntries

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(Set(entries[0].rows.map(\.number)), [1, 2])
    }

    func testStackSplitByForLaterKeepsItsNumbers() {
        let rows = [
            stacked(3, base: "step-2", head: "step-3", updated: 30),
            stacked(2, base: "step-1", head: "step-2", updated: 20),
            stacked(1, base: "main", head: "step-1", updated: 10)
        ]

        let sections = MyPullRequestSections(rows: rows, forLaterIDs: ["acme/widgets#3"])

        XCTAssertEqual(sections.active.map(\.number), [1, 2])
        XCTAssertEqual(sections.forLater.map(\.number), [3])
        XCTAssertEqual(sections.stackPositions["acme/widgets#3"]?.label, "3/3")
        XCTAssertEqual(sections.visibleIDs(isForLaterExpanded: true),
                       ["acme/widgets#1", "acme/widgets#2", "acme/widgets#3"])
    }

    func testHelpTextNamesTheBasePullRequest() {
        let bottom = PullRequestStackPosition(stackID: "x", number: 1, count: 2, basePullRequestNumber: nil)
        let top = PullRequestStackPosition(stackID: "x", number: 2, count: 2, basePullRequestNumber: 41)

        XCTAssertEqual(bottom.helpText, "Pull request 1 of 2 in a stack.\nThe bottom of the stack.")
        XCTAssertEqual(top.helpText, "Pull request 2 of 2 in a stack.\nBased on #41.")
    }

    private func stacked(_ number: Int, base: String, head: String, updated: TimeInterval,
                         repo: String = "acme/widgets") -> PullRequestRow {
        let pr = row(number: number, status: .success, updatedAt: Date(timeIntervalSince1970: updated),
                     baseRefName: base, headRefName: head)
        guard repo != pr.repoFullName else { return pr }
        return PullRequestRow(id: "\(repo)#\(number)", nodeID: pr.nodeID, title: pr.title, number: number,
                              repoFullName: repo, htmlURL: pr.htmlURL, headSHA: pr.headSHA, status: pr.status,
                              isDraft: false, isAutoMergeEnabled: false, canEnableAutoMerge: false,
                              canDisableAutoMerge: false, isMergeQueueEnabled: false, isInMergeQueue: false,
                              mergeStateStatus: "CLEAN", updatedAt: pr.updatedAt,
                              baseRefName: base, headRefName: head)
    }
}
