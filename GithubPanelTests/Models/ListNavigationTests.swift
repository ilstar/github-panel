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

    func testSelectionStaysWhileTheRowIsListed() {
        XCTAssertEqual(ListNavigation.selection(after: "b", oldIDs: ids, newIDs: ["c", "b"]), "b")
    }

    func testSelectionMovesToTheNextRowWhenItsRowLeaves() {
        XCTAssertEqual(ListNavigation.selection(after: "a", oldIDs: ids, newIDs: ["b", "c"]), "b")
        XCTAssertEqual(ListNavigation.selection(after: "b", oldIDs: ids, newIDs: ["a", "c"]), "c")
    }

    func testSelectionMovesUpWhenTheLastRowLeaves() {
        XCTAssertEqual(ListNavigation.selection(after: "c", oldIDs: ids, newIDs: ["a", "b"]), "b")
    }

    func testSelectionStartsAtTheTopWithoutAPreviousRow() {
        XCTAssertEqual(ListNavigation.selection(after: nil, oldIDs: [], newIDs: ids), "a")
        XCTAssertEqual(ListNavigation.selection(after: "gone", oldIDs: [], newIDs: ids), "a")
        XCTAssertEqual(ListNavigation.selection(after: "b", oldIDs: [], newIDs: ids), "b")
        XCTAssertNil(ListNavigation.selection(after: "a", oldIDs: ids, newIDs: []))
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
