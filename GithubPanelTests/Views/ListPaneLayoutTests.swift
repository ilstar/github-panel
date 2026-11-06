import XCTest
import AppKit
import SwiftUI
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
        // 760 - 420 detail - 1 divider leaves 339, below the list minimum, so the minimum wins.
        XCTAssertEqual(ListPaneLayout.clampedWidth(760, totalWidth: 760), ListPaneLayout.minWidth)
        XCTAssertEqual(ListPaneLayout.clampedWidth(760, totalWidth: 1100), 679)
    }

    func testListCanShrinkWellBelowItsDefault() {
        XCTAssertEqual(ListPaneLayout.clampedWidth(360, totalWidth: 1400), 360)
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

    func testDefaultWindowKeepsTheDefaultListWidthAndRoomForThePullRequest() {
        let size = ListPaneLayout.defaultWindowSize
        XCTAssertEqual(ListPaneLayout.clampedWidth(ListPaneLayout.defaultWidth, totalWidth: size.width),
                       ListPaneLayout.defaultWidth)
        XCTAssertGreaterThanOrEqual(size.width - ListPaneLayout.defaultWidth - ListPaneLayout.dividerWidth, 700)
        XCTAssertGreaterThan(size.height, 500)
    }

    func testMainWindowOpensAtTheDefaultSize() throws {
        let source = try String(contentsOf: TestPaths.url("GithubPanel/App/GithubPanelApp.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".environmentObject(monitor)\n        }\n        .defaultSize(ListPaneLayout.defaultWindowSize)"))
    }

    @MainActor
    func testPullRequestPaneFloatsInItsOwnPanelLikeTheSidebar() throws {
        let size = CGSize(width: 1200, height: 300)
        let listWidth = ListPaneLayout.clampedWidth(400, totalWidth: size.width)
        // A red sidebar marks where the panel is, so the samples below are known to miss it.
        let backdrop = WindowBackdrop(listPaneWidth: 400) { Color(red: 1, green: 0, blue: 0) }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: backdrop)
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB))
        }

        let sidebar = try color(listWidth / 2, 150)
        XCTAssertGreaterThan(sidebar.redComponent, 0.9)
        XCTAssertLessThan(sidebar.greenComponent, 0.3)

        // The pane's panel is lighter than the board around it: in the gap between the two panels, and
        // along the window's left, right and bottom edges.
        let panel = try color(listWidth + (size.width - listWidth) / 2, 150).greenComponent
        let gapBetweenPanels = listWidth + ListPaneLayout.dividerWidth - Theme.sidebarInset / 2
        for (x, y) in [(2, 150), (gapBetweenPanels, 150), (size.width - 2, 150), (listWidth + 200, size.height - 2)] {
            XCTAssertGreaterThan(panel, try color(x, y).greenComponent + 0.02, "\(x), \(y)")
        }
    }
}
