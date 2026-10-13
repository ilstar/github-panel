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

    func testParsesPipeTable() {
        let markdown = """
        Debug build:
        | | main | this PR |
        |---|:---:|---:|
        | Unified | 1,101 ms | 152 ms |
        | Split | `a \\| b` |
        - after
        """

        XCTAssertEqual(MarkdownBlocks.parse(markdown), [
            .paragraph("Debug build:"),
            .table(header: ["", "main", "this PR"],
                   alignments: [.leading, .center, .trailing],
                   rows: [["Unified", "1,101 ms", "152 ms"], ["Split", "`a | b`", ""]]),
            .listItem(marker: "•", indent: 0, text: "after")
        ])
    }

    func testTableWithoutLeadingPipesEndsAtBlankLine() {
        XCTAssertEqual(MarkdownBlocks.parse("a | b\n--- | ---\n1 | 2\n\nafter"), [
            .table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["1", "2"]]),
            .paragraph("after")
        ])
    }

    func testPipeWithoutDelimiterRowIsAParagraph() {
        XCTAssertEqual(MarkdownBlocks.parse("a | b\nc | d"), [.paragraph("a | b\nc | d")])
    }

    func testDelimiterRowMustMatchHeaderColumnCount() {
        XCTAssertEqual(MarkdownBlocks.parse("| a | b |\n| --- |"), [.paragraph("| a | b |\n| --- |")])
    }

    func testParsesTaskListItems() {
        let markdown = """
        - [ ] Write tests
          - [x] Nested **done**
        * [X] Capital X
        1. [ ] Numbered
        - [ ]
        - [x]no space
        - [] not a task
        """

        XCTAssertEqual(MarkdownBlocks.parse(markdown), [
            .task(index: 0, checked: false, indent: 0, text: "Write tests"),
            .task(index: 1, checked: true, indent: 1, text: "Nested **done**"),
            .task(index: 2, checked: true, indent: 0, text: "Capital X"),
            .task(index: 3, checked: false, indent: 0, text: "Numbered"),
            .task(index: 4, checked: false, indent: 0, text: ""),
            .listItem(marker: "•", indent: 0, text: "[x]no space"),
            .listItem(marker: "•", indent: 0, text: "[] not a task")
        ])
    }

    func testSettingTaskChangesOnlyThatBox() {
        let markdown = "## Todo\r\n- [ ] one\r\n- [x] two\r\n* [X] three"

        XCTAssertEqual(MarkdownBlocks.settingTask(0, checked: true, in: markdown),
                       "## Todo\r\n- [x] one\r\n- [x] two\r\n* [X] three")
        XCTAssertEqual(MarkdownBlocks.settingTask(2, checked: false, in: markdown),
                       "## Todo\r\n- [ ] one\r\n- [x] two\r\n* [ ] three")
        XCTAssertEqual(MarkdownBlocks.settingTask(1, checked: true, in: markdown), markdown)
        XCTAssertNil(MarkdownBlocks.settingTask(3, checked: true, in: markdown))
    }

    func testSettingTaskSkipsBoxesInCodeAndHTMLComments() {
        let markdown = """
        <!-- - [ ] template hint -->
        ```
        - [ ] in code
        ```
        Intro <!--
        - [ ] hidden
        --> ✅ - [ ] after comment
        - [ ] real
        """

        XCTAssertEqual(MarkdownBlocks.parse(markdown).last, .task(index: 0, checked: false, indent: 0, text: "real"))
        XCTAssertEqual(MarkdownBlocks.settingTask(0, checked: true, in: markdown),
                       markdown.replacingOccurrences(of: "- [ ] real", with: "- [x] real"))
    }

    func testRendersCenteredHTMLBlockFromBotComment() {
        let markdown = """
        <div align="center" id="salsa-ref">

        ## 🚀 Ready for Review? 🚀

        Mark your PR as ready and automatically assign the right reviewers.

        <br>
        <sub><sup>Let reviewers know this PR is ready for review</sup></sub>

        </div>
        """

        XCTAssertEqual(MarkdownBlocks.parse(markdown), [
            .centered([
                .heading(level: 2, text: "🚀 Ready for Review? 🚀"),
                .paragraph("Mark your PR as ready and automatically assign the right reviewers."),
                .paragraph("Let reviewers know this PR is ready for review")
            ])
        ])
    }

    func testHTMLBlockTagsOnOneLine() {
        let markdown = """
        <h3>Title</h3>
        <p align="center"><img src="logo.png" alt="Logo"></p>
        <details><summary>More</summary>
        Hidden text
        </details>
        <hr>
        After
        """

        XCTAssertEqual(MarkdownBlocks.parse(markdown), [
            .heading(level: 3, text: "Title"),
            .centered([.paragraph("Logo")]),
            .paragraph("**More**"),
            .paragraph("Hidden text"),
            .rule,
            .paragraph("After")
        ])
    }

    func testUnclosedCenteredDivEndsWithTheText() {
        XCTAssertEqual(MarkdownBlocks.parse("<center>\nHi"), [.centered([.paragraph("Hi")])])
    }

    func testInlineHTMLBecomesMarkdown() {
        XCTAssertEqual(
            MarkdownBlocks.inlineHTML(#"<b>Bold</b> <em>it</em> <a href="https://x.dev">link</a><br/>next <code>x</code>"#),
            "**Bold** *it* [link](https://x.dev)\nnext `x`"
        )
        XCTAssertEqual(MarkdownBlocks.inlineHTML("<a name=\"top\"></a>Top &amp; tail&nbsp;&#128640;"),
                       "Top & tail\u{00A0}🚀")
    }

    func testInlineHTMLLeavesCodeSpansAndUnknownTagsAlone() {
        XCTAssertEqual(MarkdownBlocks.inlineHTML("Use `<b>` with Array<Int> & a < b"),
                       "Use `<b>` with Array<Int> & a < b")
    }

    func testHTMLInListItemsAndTasks() {
        XCTAssertEqual(MarkdownBlocks.parse("- <b>Bold</b> item\n- [x] <i>Done</i>"), [
            .listItem(marker: "•", indent: 0, text: "**Bold** item"),
            .task(index: 0, checked: true, indent: 0, text: "*Done*")
        ])
    }

    func testSettingTaskInsideCenteredHTML() {
        let markdown = "<div align=\"center\">\n\n- [ ] Go\n\n</div>"

        XCTAssertEqual(MarkdownBlocks.parse(markdown), [.centered([.task(index: 0, checked: false, indent: 0, text: "Go")])])
        XCTAssertEqual(MarkdownBlocks.settingTask(0, checked: true, in: markdown),
                       "<div align=\"center\">\n\n- [x] Go\n\n</div>")
    }
}
