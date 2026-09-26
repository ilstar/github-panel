import XCTest
import AppKit
@testable import GithubPanel

@MainActor
final class PageScrollerTests: XCTestCase {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private func scrollView(documentHeight: CGFloat, flipped: Bool = true) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = flipped ? FlippedView() : NSView()
        document.frame = NSRect(x: 0, y: 0, width: 300, height: documentHeight)
        scrollView.documentView = document
        return scrollView
    }

    func testPagesDownByTheVisibleHeightLessTheOverlap() {
        let view = scrollView(documentHeight: 1000)

        PageScroller.page(view, down: true)

        XCTAssertEqual(view.contentView.bounds.origin.y, 200 - PageScroller.overlap)
    }

    func testStopsAtTheBottomAndTheTop() {
        let view = scrollView(documentHeight: 500)

        for _ in 0..<5 { PageScroller.page(view, down: true) }
        XCTAssertEqual(view.contentView.bounds.origin.y, 300)

        for _ in 0..<5 { PageScroller.page(view, down: false) }
        XCTAssertEqual(view.contentView.bounds.origin.y, 0)
    }

    func testPageDownInAnUnflippedDocumentMovesTowardZero() {
        let view = scrollView(documentHeight: 1000, flipped: false)
        view.contentView.scroll(to: NSPoint(x: 0, y: 800))

        PageScroller.page(view, down: true)

        XCTAssertEqual(view.contentView.bounds.origin.y, 800 - (200 - PageScroller.overlap))
    }

    func testDoesNothingWithoutAScrollView() {
        PageScroller().page(down: true)
    }
}
