import XCTest
@testable import GithubPanel

final class TitleBarDoubleClickTests: XCTestCase {
    func testDoubleClickFollowsTheSystemSetting() {
        XCTAssertEqual(TitleBarDoubleClickAction(preference: nil), .zoom)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "Maximize"), .zoom)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "Fill"), .zoom)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "Minimize"), .minimize)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "None"), TitleBarDoubleClickAction.none)
    }

    func testOnlyTheTopStripCountsAsTheTitleBar() {
        XCTAssertTrue(TitleBarDoubleClickView.isInTitleBar(NSPoint(x: 10, y: 590), windowHeight: 600, titleBarHeight: 28))
        XCTAssertTrue(TitleBarDoubleClickView.isInTitleBar(NSPoint(x: 10, y: 572), windowHeight: 600, titleBarHeight: 28))
        XCTAssertFalse(TitleBarDoubleClickView.isInTitleBar(NSPoint(x: 10, y: 571), windowHeight: 600, titleBarHeight: 28))
        XCTAssertFalse(TitleBarDoubleClickView.isInTitleBar(NSPoint(x: 10, y: 599), windowHeight: 600, titleBarHeight: 0))
    }

    func testDoubleClickZoomsTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: true)
        XCTAssertGreaterThan(TitleBarDoubleClickView.titleBarHeight(of: window), 0)

        let before = window.frame
        TitleBarDoubleClickAction.zoom.perform(on: window)
        XCTAssertNotEqual(window.frame, before)
    }
}
