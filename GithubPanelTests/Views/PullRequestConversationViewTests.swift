import AppKit
import SwiftUI
import XCTest
@testable import GithubPanel

@MainActor
final class PullRequestConversationViewTests: XCTestCase {
    /// Reviewers sit beside the description when there is room, and move above it in a narrow pane.
    func testSidebarShowsBesideTheDescriptionOnlyWhenItFits() {
        XCTAssertTrue(PullRequestConversationView.showsSidebar(paneWidth: 1000))
        XCTAssertTrue(PullRequestConversationView.showsSidebar(paneWidth: 732))
        XCTAssertFalse(PullRequestConversationView.showsSidebar(paneWidth: 731))
        XCTAssertFalse(PullRequestConversationView.showsSidebar(paneWidth: 420))
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
