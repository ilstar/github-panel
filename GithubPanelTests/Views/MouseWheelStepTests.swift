import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

@MainActor
final class MouseWheelStepTests: XCTestCase {
    func testSetsTheLineScrollOfTheScrollViewItSitsIn() throws {
        let (window, scrollView) = try hostScrollView(withStep: true)
        defer { window.orderOut(nil) }

        XCTAssertEqual(scrollView.verticalLineScroll, MouseWheelStep.points)
        XCTAssertEqual(scrollView.horizontalLineScroll, MouseWheelStep.points)
    }

    func testOneWheelNotchMovesByTheStep() throws {
        let (window, scrollView) = try hostScrollView(withStep: true)
        defer { window.orderOut(nil) }

        XCTAssertEqual(try scrollDistance(scrollView, units: .line, amount: 1), MouseWheelStep.points, accuracy: 0.5)
    }

    func testAPlainScrollViewMovesLessPerNotch() throws {
        let (window, scrollView) = try hostScrollView(withStep: false)
        defer { window.orderOut(nil) }

        XCTAssertLessThan(try scrollDistance(scrollView, units: .line, amount: 1), MouseWheelStep.points)
    }

    func testTrackpadScrollingIsUnchanged() throws {
        let (plainWindow, plain) = try hostScrollView(withStep: false)
        defer { plainWindow.orderOut(nil) }
        let (window, stepped) = try hostScrollView(withStep: true)
        defer { window.orderOut(nil) }

        XCTAssertEqual(try scrollDistance(stepped, units: .pixel, amount: 25),
                       try scrollDistance(plain, units: .pixel, amount: 25),
                       accuracy: 0.5)
    }

    private func scrollDistance(_ scrollView: NSScrollView, units: CGScrollEventUnit, amount: Int32) throws -> CGFloat {
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1,
                                            wheel1: -amount, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        let before = scrollView.contentView.bounds.origin.y
        scrollView.scrollWheel(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return scrollView.contentView.bounds.origin.y - before
    }

    private func hostScrollView(withStep: Bool) throws -> (NSWindow, NSScrollView) {
        let content = ScrollView {
            if withStep {
                Color.clear.frame(height: 2000).mouseWheelStep()
            } else {
                Color.clear.frame(height: 2000)
            }
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
