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

    func testTabSwitcherInTheTitleBarStripStartsAfterTheWindowButtons() throws {
        // The switcher shares the title bar strip with the window buttons, so it must begin to their right.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.titlebarAppearsTransparent = true
        WindowToolbarStripView.install(in: window)

        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let buttonsEnd = zoom.convert(zoom.bounds, to: nil).maxX
        let switcherStart = ContentView.listLeadingPadding + ContentView.windowButtonsWidth

        XCTAssertLessThanOrEqual(buttonsEnd + 6, switcherStart)
        // And not so far that it leaves a wide empty gap.
        XCTAssertLessThanOrEqual(switcherStart - buttonsEnd, 24)
    }
}
