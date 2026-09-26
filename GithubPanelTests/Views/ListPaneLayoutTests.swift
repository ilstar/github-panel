import XCTest
@testable import GithubPanel

final class ListPaneLayoutTests: XCTestCase {
    func testWidthWithinLimitsIsKept() {
        XCTAssertEqual(ListPaneLayout.clampedWidth(650, totalWidth: 1400), 650)
    }

    func testWidthIsClampedToListLimits() {
        XCTAssertEqual(ListPaneLayout.clampedWidth(100, totalWidth: 1400), ListPaneLayout.minWidth)
        XCTAssertEqual(ListPaneLayout.clampedWidth(2000, totalWidth: 1400), ListPaneLayout.maxWidth)
    }

    func testWidthLeavesRoomForDetailPane() {
        // 1000 - 420 detail - 1 divider leaves 579, below the list minimum, so the minimum wins.
        XCTAssertEqual(ListPaneLayout.clampedWidth(760, totalWidth: 1000), ListPaneLayout.minWidth)
        XCTAssertEqual(ListPaneLayout.clampedWidth(760, totalWidth: 1100), 679)
    }

    func testDefaultWidthIsWithinLimits() {
        XCTAssertEqual(ListPaneLayout.clampedWidth(ListPaneLayout.defaultWidth, totalWidth: 1400),
                       ListPaneLayout.defaultWidth)
    }
}
