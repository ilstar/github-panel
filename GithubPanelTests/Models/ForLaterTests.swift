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
