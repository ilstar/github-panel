import SwiftUI
import XCTest
@testable import GithubPanel

final class MarkdownInlineCodeTests: XCTestCase {
    /// Inline code sits on a soft fill with a thin space inside each end; the text around it is left alone.
    func testInlineCodeGetsAFillAndThinSpaces() {
        let text = MarkdownView.inline("Set `optional:` here")
        let pad = MarkdownView.inlineCodePadding
        XCTAssertEqual(String(text.characters), "Set \(pad)optional:\(pad) here")

        let filled = text.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(filled.count, 1)
        XCTAssertEqual(filled.first.map { String(text[$0.range].characters) }, "\(pad)optional:\(pad)")
        XCTAssertEqual(filled.first?.inlinePresentationIntent?.contains(.code), true)
    }

    func testTextWithoutCodeIsUnchanged() {
        let text = MarkdownView.inline("Plain **bold** words")
        XCTAssertEqual(String(text.characters), "Plain bold words")
        XCTAssertTrue(text.runs.allSatisfy { $0.backgroundColor == nil })
    }
}
