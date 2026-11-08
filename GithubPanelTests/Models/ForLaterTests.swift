import XCTest
@testable import GithubPanel

final class ForLaterTests: XCTestCase {
    func testSplitsRowsKeepingGitHubOrder() {
        let rows = [row(number: 1, status: .success), row(number: 2, status: .success), row(number: 3, status: .success), row(number: 4, status: .success)]

        let sections = MyPullRequestSections(rows: rows, forLaterIDs: ["acme/widgets#3", "acme/widgets#1"])

        XCTAssertEqual(sections.active.map(\.number), [2, 4])
        XCTAssertEqual(sections.forLater.map(\.number), [1, 3])
    }

    func testIgnoresForLaterIDsThatAreNotOpen() {
        let sections = MyPullRequestSections(rows: [row(number: 1, status: .success)], forLaterIDs: ["acme/widgets#9"])

        XCTAssertEqual(sections.active.map(\.number), [1])
        XCTAssertTrue(sections.forLater.isEmpty)
    }

    func testVisibleIDsDropForLaterRowsWhenCollapsed() {
        let sections = MyPullRequestSections(rows: [row(number: 1, status: .success), row(number: 2, status: .success)], forLaterIDs: ["acme/widgets#1"])

        XCTAssertEqual(sections.visibleIDs(isForLaterExpanded: true), ["acme/widgets#2", "acme/widgets#1"])
        XCTAssertEqual(sections.visibleIDs(isForLaterExpanded: false), ["acme/widgets#2"])
    }

    func testGroupsRowsMostUrgentFirstKeepingGitHubOrder() {
        let rows = [row(number: 1, status: .pending),
                    row(number: 2, status: .failure),
                    row(number: 3, status: .success),
                    row(number: 4, status: .pending),
                    row(number: 5, status: .success, isDraft: true),
                    row(number: 6, status: .success, mergeStateStatus: "DIRTY")]

        let sections = MyPullRequestSections(rows: rows, forLaterIDs: [])

        XCTAssertEqual(sections.groups.map(\.group), [.needsYou, .readyToMerge, .building, .drafts])
        XCTAssertEqual(sections.groups.map { $0.rows.map(\.number) }, [[2, 6], [3], [1, 4], [5]])
        XCTAssertEqual(sections.active.map(\.number), [2, 6, 3, 1, 4, 5])
        XCTAssertEqual(sections.needsYouCount, 2)
        XCTAssertEqual(sections.statuses["acme/widgets#2"]?.reason, "Checks failed")
    }

    func testForLaterRowsStayOutOfTheGroups() {
        let rows = [row(number: 1, status: .failure), row(number: 2, status: .failure)]

        let sections = MyPullRequestSections(rows: rows, forLaterIDs: ["acme/widgets#1"])

        XCTAssertEqual(sections.groups.first?.rows.map(\.number), [2])
        XCTAssertEqual(sections.needsYouCount, 1)
        XCTAssertNil(sections.group(containing: "acme/widgets#1"))
        XCTAssertEqual(sections.group(containing: "acme/widgets#2"), .needsYou)
    }

    func testStackGoesInItsMostUrgentGroup() {
        let rows = [row(number: 1, status: .success, baseRefName: "main", headRefName: "bottom"),
                    row(number: 2, status: .failure, baseRefName: "bottom", headRefName: "top"),
                    row(number: 3, status: .pending)]

        let sections = MyPullRequestSections(rows: rows, forLaterIDs: [])

        XCTAssertEqual(sections.groups.map(\.group), [.needsYou, .building])
        XCTAssertEqual(sections.groups.first?.rows.map(\.number), [1, 2])
        XCTAssertEqual(sections.statuses["acme/widgets#1"]?.group, .readyToMerge)
    }

    func testVisibleIDsDropCollapsedGroups() {
        let rows = [row(number: 1, status: .failure), row(number: 2, status: .pending), row(number: 3, status: .success)]

        let sections = MyPullRequestSections(rows: rows, forLaterIDs: ["acme/widgets#3"])

        XCTAssertEqual(sections.visibleIDs(collapsed: [.building], isForLaterExpanded: true), ["acme/widgets#1", "acme/widgets#3"])
        XCTAssertEqual(sections.visibleIDs(collapsed: [.needsYou], isForLaterExpanded: false), ["acme/widgets#2"])
    }

    func testWithoutGroupingRowsKeepGitHubOrderAndIgnoreCollapsedGroups() {
        let rows = [row(number: 1, status: .pending), row(number: 2, status: .failure), row(number: 3, status: .success)]

        let sections = MyPullRequestSections(rows: rows, forLaterIDs: ["acme/widgets#3"])

        XCTAssertEqual(sections.listEntries.flatMap(\.rows).map(\.number), [1, 2])
        XCTAssertEqual(sections.visibleIDs(groupsByStatus: false, collapsed: [.needsYou, .building], isForLaterExpanded: true),
                       ["acme/widgets#1", "acme/widgets#2", "acme/widgets#3"])
        XCTAssertEqual(sections.needsYouCount, 1)
    }

    func testStorageRoundTrips() {
        let ids: Set<String> = ["acme/widgets#2", "acme/widgets#1"]

        XCTAssertEqual(ForLaterStorage.decode(ForLaterStorage.encode(ids)), ids)
        XCTAssertEqual(ForLaterStorage.encode(ids), #"["acme\/widgets#1","acme\/widgets#2"]"#)
    }

    func testStorageReadsMissingOrBadValuesAsEmpty() {
        XCTAssertEqual(ForLaterStorage.decode(nil), [])
        XCTAssertEqual(ForLaterStorage.decode("not json"), [])
    }
}
