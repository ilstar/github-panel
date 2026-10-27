import SwiftUI
import XCTest
@testable import GithubPanel

final class MarkdownInlineCodeTests: XCTestCase {
    /// Inline code keeps its code style with a narrow space inside each end; the text around it is left alone.
    func testInlineCodeIsPaddedAndKeepsItsCodeStyle() {
        let text = MarkdownView.inline("Set `optional:` here")
        let pad = MarkdownView.inlineCodePadding
        XCTAssertEqual(String(text.characters), "Set \(pad)optional:\(pad) here")

        let code = text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertEqual(code.map { String(text[$0.range].characters) }, ["\(pad)optional:\(pad)"])
        XCTAssertNotNil(code.first?.foregroundColor)
    }

    /// Neighboring code runs on a line share one rounded fill; text between spans splits them.
    @available(macOS 15.0, *)
    func testRendererMergesNeighboringCodeRunsIntoOneFill() {
        let rects = InlineCodeRenderer.codeRects([
            (CGRect(x: 0, y: 0, width: 10, height: 16), false),
            (CGRect(x: 10, y: 0, width: 20, height: 16), true),
            (CGRect(x: 30, y: 0, width: 15, height: 16), true),
            (CGRect(x: 45, y: 0, width: 10, height: 16), false),
            (CGRect(x: 55, y: 0, width: 5, height: 16), true)
        ])
        XCTAssertEqual(rects, [CGRect(x: 10, y: 0, width: 35, height: 16), CGRect(x: 55, y: 0, width: 5, height: 16)])
    }

    /// The padding must not be a place to wrap, or a line can end in an empty patch of fill.
    func testInlineCodePaddingDoesNotAllowALineBreak() {
        XCTAssertEqual(MarkdownView.inlineCodePadding, "\u{202F}", "narrow no-break space")
    }

    func testTextWithoutCodeIsUnchanged() {
        let text = MarkdownView.inline("Plain **bold** words")
        XCTAssertEqual(String(text.characters), "Plain bold words")
        XCTAssertTrue(text.runs.allSatisfy { $0.foregroundColor == nil })
    }
}
