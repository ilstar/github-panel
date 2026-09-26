import XCTest
@testable import GithubPanel

final class ListNavigationTests: XCTestCase {
    private let ids = ["a", "b", "c"]

    func testMovesByTheOffset() {
        XCTAssertEqual(ListNavigation.neighbor(of: "a", in: ids, offset: 1), "b")
        XCTAssertEqual(ListNavigation.neighbor(of: "c", in: ids, offset: -1), "b")
        XCTAssertEqual(ListNavigation.neighbor(of: "a", in: ids, offset: 2), "c")
    }

    func testStopsAtEitherEnd() {
        XCTAssertEqual(ListNavigation.neighbor(of: "c", in: ids, offset: 1), "c")
        XCTAssertEqual(ListNavigation.neighbor(of: "a", in: ids, offset: -1), "a")
    }

    func testStartsFromTheFirstWhenNothingIsSelected() {
        XCTAssertEqual(ListNavigation.neighbor(of: nil, in: ids, offset: 1), "a")
        XCTAssertEqual(ListNavigation.neighbor(of: nil, in: ids, offset: -1), "a")
        XCTAssertEqual(ListNavigation.neighbor(of: "gone", in: ids, offset: 1), "a")
    }

    func testEmptyListHasNoNeighbor() {
        XCTAssertNil(ListNavigation.neighbor(of: "a", in: [String](), offset: 1))
    }

    func testDetailTabsWrapAround() {
        XCTAssertEqual(PullRequestDetailTab.conversation.next, .files)
        XCTAssertEqual(PullRequestDetailTab.files.next, .conversation)
        XCTAssertEqual(PullRequestDetailTab.conversation.previous, .files)
        XCTAssertEqual(PullRequestDetailTab.files.previous, .conversation)
    }
}
