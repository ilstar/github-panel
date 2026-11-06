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
    func testBackdropIsOneColorBesideTheSidebarAndUnderThePullRequestPane() throws {
        // A red sidebar marks where the panel is, so the samples below are known to miss it.
        let size = CGSize(width: 1000, height: 300)
        let listWidth = 400.0
        let backdrop = WindowBackdrop(listPaneWidth: listWidth) { Color(red: 1, green: 0, blue: 0) }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: backdrop)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)

        let gapBesideSidebar = try XCTUnwrap(bitmap.colorAt(x: 2, y: 150)?.usingColorSpace(.sRGB))
        let underSidebar = try XCTUnwrap(bitmap.colorAt(x: 100, y: 150)?.usingColorSpace(.sRGB))
        let underPullRequest = try XCTUnwrap(bitmap.colorAt(x: 800, y: 150)?.usingColorSpace(.sRGB))

        XCTAssertGreaterThan(underSidebar.redComponent, 0.9)
        XCTAssertLessThan(underSidebar.greenComponent, 0.3)
        XCTAssertEqual(gapBesideSidebar.redComponent, underPullRequest.redComponent, accuracy: 0.01)
        XCTAssertEqual(gapBesideSidebar.greenComponent, underPullRequest.greenComponent, accuracy: 0.01)
        XCTAssertEqual(gapBesideSidebar.blueComponent, underPullRequest.blueComponent, accuracy: 0.01)
    }
}
