import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

@MainActor
final class ScrollActivityTests: XCTestCase {
    func testIsNotScrollingBeforeAnyMovement() {
        XCTAssertFalse(ScrollActivity().isScrolling(at: 100))
    }

    func testCountsAsScrollingUntilTheSettleIntervalPasses() {
        let activity = ScrollActivity()

        activity.noteMovement(at: 100)

        XCTAssertTrue(activity.isScrolling(at: 100))
        XCTAssertTrue(activity.isScrolling(at: 100 + ScrollActivity.settleInterval / 2))
        XCTAssertFalse(activity.isScrolling(at: 100 + ScrollActivity.settleInterval))
    }

    func testEachMovementRestartsTheSettleInterval() {
        let activity = ScrollActivity()

        activity.noteMovement(at: 100)
        activity.noteMovement(at: 100 + ScrollActivity.settleInterval / 2)

        XCTAssertTrue(activity.isScrolling(at: 100 + ScrollActivity.settleInterval))
    }

    func testMonitorRecordsMovementOfTheScrollViewItSitsIn() throws {
        let activity = ScrollActivity()
        let (window, scrollView) = try hostScrollView(activity: activity)
        defer { window.orderOut(nil) }
        XCTAssertFalse(activity.isScrolling())

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        XCTAssertTrue(activity.isScrolling())
    }

    func testMonitorStopsRecordingOnceRemovedFromTheWindow() throws {
        let activity = ScrollActivity()
        let (window, scrollView) = try hostScrollView(activity: activity)
        defer { window.orderOut(nil) }
        let hostedScrollView = scrollView

        window.contentView = nil
        hostedScrollView.contentView.scroll(to: NSPoint(x: 0, y: 300))

        XCTAssertFalse(activity.isScrolling())
    }

    private func hostScrollView(activity: ScrollActivity) throws -> (NSWindow, NSScrollView) {
        let content = ScrollView {
            Color.clear
                .frame(height: 2000)
                .background(ScrollActivityMonitor(activity: activity))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(Self.scrollViews(in: host).first)
        return (window, scrollView)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
}
