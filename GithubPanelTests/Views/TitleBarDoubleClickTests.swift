import XCTest
import SwiftUI
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

    @MainActor
    func testTitleBarStripTakesClicksEvenWhenPaneBackgroundsRunUnderIt() throws {
        let window = makeStripWindow()
        defer { window.close() }
        // Like ContentView: pane backgrounds run up under the hidden title bar, with the title bar area over them.
        window.contentView = NSHostingView(rootView: Color.clear.background(stripBackground))
        window.layoutIfNeeded()

        XCTAssertTrue(hit(window, at: NSPoint(x: 300, y: 395)) is TitleBarDoubleClickView)
        XCTAssertFalse(hit(window, at: NSPoint(x: 300, y: 200)) is TitleBarDoubleClickView)
    }

    @MainActor
    func testControlsInTheTitleBarStripTakeTheirOwnClicks() throws {
        let window = makeStripWindow()
        defer { window.close() }
        // Like the refresh button and the pull request toolbar, which sit in the strip.
        let root = VStack {
            Button("Refresh") {}
                .frame(width: 120, height: 30)
                .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .background(stripBackground)
        window.contentView = NSHostingView(rootView: root)
        window.layoutIfNeeded()

        let titleBarHeight = TitleBarDoubleClickView.titleBarHeight(of: window)
        XCTAssertGreaterThan(titleBarHeight, 36, "The toolbar strip should make the title bar taller")
        XCTAssertFalse(hit(window, at: NSPoint(x: 300, y: 400 - 21)) is TitleBarDoubleClickView)
        XCTAssertTrue(hit(window, at: NSPoint(x: 40, y: 400 - 21)) is TitleBarDoubleClickView)
    }

    func testToolbarStripIsInstalledOnce() {
        let window = makeStripWindow()
        defer { window.close() }
        let toolbar = window.toolbar
        WindowToolbarStripView.install(in: window)
        XCTAssertTrue(window.toolbar === toolbar)
        XCTAssertEqual(window.toolbar?.identifier, WindowToolbarStripView.toolbarIdentifier)
    }

    private var stripBackground: some View {
        ZStack {
            Color.white
            TitleBarDoubleClickArea()
        }
        .ignoresSafeArea()
    }

    private func makeStripWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        WindowToolbarStripView.install(in: window)
        return window
    }

    /// The view a click lands on, for a point in window coordinates.
    private func hit(_ window: NSWindow, at point: NSPoint) -> NSView? {
        guard let frameView = window.contentView?.superview else { return nil }
        return frameView.hitTest(frameView.convert(point, from: nil))
    }
}
