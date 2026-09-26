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
        // 800 - 420 detail - 1 divider leaves 379, below the list minimum, so the minimum wins.
        XCTAssertEqual(ListPaneLayout.clampedWidth(760, totalWidth: 800), ListPaneLayout.minWidth)
        XCTAssertEqual(ListPaneLayout.clampedWidth(760, totalWidth: 1100), 679)
    }

    func testListCanShrinkWellBelowItsDefault() {
        XCTAssertEqual(ListPaneLayout.clampedWidth(440, totalWidth: 1400), 440)
    }

    func testMinimumWindowFitsBothPanesAtTheirMinimums() {
        let total = ListPaneLayout.minWindowWidth
        XCTAssertEqual(ListPaneLayout.clampedWidth(ListPaneLayout.minWidth, totalWidth: total), ListPaneLayout.minWidth)
        XCTAssertEqual(total - ListPaneLayout.minWidth - ListPaneLayout.dividerWidth, ListPaneLayout.minDetailWidth)
    }

    func testDefaultWidthIsWithinLimits() {
        XCTAssertEqual(ListPaneLayout.clampedWidth(ListPaneLayout.defaultWidth, totalWidth: 1400),
                       ListPaneLayout.defaultWidth)
    }
}
