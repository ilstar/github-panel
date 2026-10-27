import AppKit
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

    /// Markdown text is selectable, and selectable text skips custom text renderers, so the fill has to be
    /// drawn another way. Counts the fill's gray pixels against the same words without code.
    @MainActor
    func testSelectableMarkdownStillDrawsTheCodeFill() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Rounded fills need macOS 15") }
        XCTAssertTrue(InlineMarkdownText.hasInlineCode("a `b` c"))
        XCTAssertFalse(InlineMarkdownText.hasInlineCode("a b c"))

        let withCode = grayPixels(MarkdownView(markdown: "aa `optional:` bb"))
        let withoutCode = grayPixels(MarkdownView(markdown: "aa optional: bb"))
        XCTAssertGreaterThan(withCode - withoutCode, 1_000)
    }

    @MainActor
    private func grayPixels(_ view: some View) -> Int {
        let host = NSHostingView(rootView: view.padding(10).background(Color.white).environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.8, color.redComponent < 0.97,
                   abs(color.redComponent - color.blueComponent) < 0.06 {
                    count += 1
                }
            }
        }
        return count
    }
}
