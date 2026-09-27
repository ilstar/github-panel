import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

@MainActor
final class ContentViewTests: XCTestCase {
    func testEmptyPullRequestsBackgroundAssetIsAvailable() {
        XCTAssertNotNil(NSImage(named: EmptyPullRequestsBackground.imageName))
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
