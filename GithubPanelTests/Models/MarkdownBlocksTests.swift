import XCTest
@testable import GithubPanel

final class MarkdownBlocksTests: XCTestCase {
    func testParsesTypicalPullRequestTemplate() {
        let markdown = """
        ## Summary

        - Adds a **detail** view.
          - Nested item
        1. First
        2) Second

        Some text
        on two lines.

        > A quote
        > continues

        ```swift
        let x = 1

        print(x)
        ```

        ---
        """

        XCTAssertEqual(MarkdownBlocks.parse(markdown), [
            .heading(level: 2, text: "Summary"),
            .listItem(marker: "•", indent: 0, text: "Adds a **detail** view."),
            .listItem(marker: "•", indent: 1, text: "Nested item"),
            .listItem(marker: "1.", indent: 0, text: "First"),
            .listItem(marker: "2.", indent: 0, text: "Second"),
            .paragraph("Some text\non two lines."),
            .quote("A quote\ncontinues"),
            .code(language: "swift", text: "let x = 1\n\nprint(x)"),
            .rule
        ])
    }

    func testStripsHTMLCommentsFromTemplates() {
        let markdown = "Intro <!-- hidden -->\n<!--\nmulti\nline\n-->\nAfter"

        XCTAssertEqual(MarkdownBlocks.parse(markdown), [.paragraph("Intro"), .paragraph("After")])
    }

    func testUnclosedCodeFenceKeepsItsLines() {
        XCTAssertEqual(MarkdownBlocks.parse("```\nstill code"), [.code(language: nil, text: "still code")])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(MarkdownBlocks.parse("#123 fixes it"), [.paragraph("#123 fixes it")])
    }

    func testCRLFLineEndings() {
        XCTAssertEqual(MarkdownBlocks.parse("# Title\r\n\r\nBody"), [.heading(level: 1, text: "Title"), .paragraph("Body")])
    }
}
