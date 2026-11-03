import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

@MainActor
final class ContentViewTests: XCTestCase {
    func testEmptyPullRequestsBackgroundAssetIsAvailable() {
        XCTAssertNotNil(NSImage(named: EmptyPullRequestsBackground.imageName))
    }

    func testEmptyPullRequestsBackgroundKeepsToTheSidebarsSize() {
        // The image is wider than the sidebar, and filling it must not widen the panel past its frame.
        let controller = NSHostingController(rootView: EmptyPullRequestsBackground(isVisible: true))
        let size = controller.sizeThatFits(in: CGSize(width: 300, height: 800))
        XCTAssertEqual(size.width, 300, accuracy: 1)
        XCTAssertEqual(size.height, 800, accuracy: 1)
    }

    func testTabPickerListsTheTabsInOrder() {
        XCTAssertEqual(PullRequestTabPicker.segments.map(\.value), PullRequestTab.allCases)
        XCTAssertEqual(PullRequestTabPicker.segments.map(\.title), ["My PRs", "To Review", "History"])
    }

    func testTabPickerFillsTheWidthOfItsRow() throws {
        // The switcher's edges line up with the rows under it, so it stretches to the row's width.
        let host = NSHostingView(rootView: PullRequestTabPicker(selection: .constant(.open)).frame(width: 420))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 40)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 420, accuracy: 1)
    }
}
