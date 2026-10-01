import AppKit
import SwiftUI
import XCTest
@testable import GithubPanel

@MainActor
final class PullRequestConversationViewTests: XCTestCase {
    /// The sidebar sits to the right of the main column when both fit, and above it otherwise.
    func testSidebarLayoutPutsTheSidebarBesideTheMainColumnOnlyWhenItFits() {
        let wide = layoutFrames(width: 1200)
        XCTAssertEqual(wide.main, CGRect(x: 0, y: 0, width: SidebarLayout.mainMaxWidth, height: 300))
        XCTAssertEqual(wide.sidebar, CGRect(x: SidebarLayout.mainMaxWidth + SidebarLayout.spacing, y: 0,
                                            width: SidebarLayout.sidebarWidth, height: 80))

        let justFits = layoutFrames(width: 668)
        XCTAssertEqual(justFits.main.width, 420)
        XCTAssertEqual(justFits.sidebar.minX, 448)

        let narrow = layoutFrames(width: 667)
        XCTAssertEqual(narrow.sidebar, CGRect(x: 0, y: 0, width: 667, height: 80))
        XCTAssertEqual(narrow.main, CGRect(x: 0, y: 80 + SidebarLayout.stackedSpacing, width: 667, height: 300))
    }

    private func layoutFrames(width: CGFloat) -> (main: CGRect, sidebar: CGRect) {
        let recorder = FrameRecorder()
        let host = NSHostingView(rootView:
            SidebarLayout {
                Color.clear.frame(height: 300).background(recorder.probe("main"))
                Color.clear.frame(height: 80).background(recorder.probe("sidebar"))
            }
            .frame(width: width, alignment: .topLeading)
            .coordinateSpace(name: FrameRecorder.space))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (recorder.frames["main"] ?? .null, recorder.frames["sidebar"] ?? .null)
    }

    /// The conversation's content stops at 900pt, but its scroller should still sit at the pane's right edge.
    func testScrollViewFillsAPaneWiderThanTheContent() throws {
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PullRequestConversationView(detail: detailContent(for: reference).detail,
                                                                       comments: [],
                                                                       onComment: { _ in },
                                                                       onSaveBody: { _ in }))
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()

        let scrollViews = Self.descendants(of: host).compactMap { $0 as? NSScrollView }
        let conversation = try XCTUnwrap(scrollViews.max { $0.frame.height < $1.frame.height })
        XCTAssertEqual(conversation.convert(conversation.bounds, to: host).maxX, host.bounds.maxX, accuracy: 0.5)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private final class FrameRecorder {
    static let space = "layout"
    var frames: [String: CGRect] = [:]

    func probe(_ name: String) -> some View {
        GeometryReader { proxy in
            Color.clear.onAppear { self.frames[name] = proxy.frame(in: .named(Self.space)) }
        }
    }
}
