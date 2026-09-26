import XCTest
@testable import GithubPanel

final class DiffPresentationTests: XCTestCase {
    func testHighlightsOnlyTheChangedWords() {
        let presentation = DiffPresentation(lines: DiffParser.parse("@@ -1 +1 @@\n-print(\"hello world\")\n+print(\"hello claude\")"),
                                            hideWhitespace: false)

        XCTAssertEqual(presentation.unified[1].segments, [
            DiffSegment(text: "print(\"hello ", isChanged: false),
            DiffSegment(text: "world", isChanged: true),
            DiffSegment(text: "\")", isChanged: false)
        ])
        XCTAssertEqual(presentation.unified[2].segments, [
            DiffSegment(text: "print(\"hello ", isChanged: false),
            DiffSegment(text: "claude", isChanged: true),
            DiffSegment(text: "\")", isChanged: false)
        ])
        XCTAssertEqual(presentation.unified[2].text, "print(\"hello claude\")")
    }

    func testPairsDeletionsAndAdditionsInOrder() {
        let patch = "@@ -1,2 +1,3 @@\n-let a = 1\n-let b = 2\n+let a = 10\n+let b = 20\n+let c = 30"

        let lines = DiffPresentation(lines: DiffParser.parse(patch), hideWhitespace: false).unified

        XCTAssertEqual(lines[1].segments.filter(\.isChanged).map(\.text), ["1"])
        XCTAssertEqual(lines[3].segments.filter(\.isChanged).map(\.text), ["10"])
        XCTAssertEqual(lines[2].segments.filter(\.isChanged).map(\.text), ["2"])
        XCTAssertEqual(lines[4].segments.filter(\.isChanged).map(\.text), ["20"])
        XCTAssertEqual(lines[5].segments, [DiffSegment(text: "let c = 30", isChanged: false)])
    }

    func testUnrelatedLinesAreNotHighlighted() {
        XCTAssertNil(DiffPresentation.wordDiff(old: "foo bar", new: "baz qux"))
    }

    func testWhitespaceBetweenChangedWordsJoinsTheChange() {
        let words = DiffPresentation.wordDiff(old: "let one two = x", new: "let three four = x")

        XCTAssertEqual(words?.old.filter(\.isChanged).map(\.text), ["one two"])
        XCTAssertEqual(words?.new.filter(\.isChanged).map(\.text), ["three four"])
    }

    func testTokensSplitWordsSpacesAndPunctuation() {
        XCTAssertEqual(DiffPresentation.tokens("  foo_bar(1, x)"), ["  ", "foo_bar", "(", "1", ",", " ", "x", ")"])
    }

    func testHidingWhitespaceTurnsIndentOnlyChangesIntoContext() {
        let patch = "@@ -4,3 +4,3 @@\n a\n-  b()\n-c\n+    b()\n+d"

        let lines = DiffPresentation.hidingWhitespaceChanges(DiffParser.parse(patch))

        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .context, .deletion, .addition])
        XCTAssertEqual(lines[2], DiffLine(kind: .context, text: "    b()", oldLineNumber: 5, newLineNumber: 5))
        XCTAssertEqual(lines[3].text, "c")
        XCTAssertEqual(lines[4].text, "d")
    }

    func testHidingWhitespaceKeepsRealChanges() {
        let lines = DiffParser.parse("@@ -1 +1 @@\n-a\n+b")

        XCTAssertEqual(DiffPresentation.hidingWhitespaceChanges(lines), lines)
    }

    func testWhitespaceOnlyDiffHasNoChangesWhenHidden() {
        let lines = DiffParser.parse("@@ -1 +1 @@\n-\tx = 1\n+    x = 1")

        XCTAssertTrue(DiffPresentation(lines: lines, hideWhitespace: false).hasChanges)
        XCTAssertFalse(DiffPresentation(lines: lines, hideWhitespace: true).hasChanges)
    }

    func testSplitRowsPairOldAndNewLines() {
        let patch = "@@ -1,3 +1,3 @@\n a\n-b\n-c\n+B\n d\n\\ No newline at end of file"

        let rows = DiffPresentation(lines: DiffParser.parse(patch), hideWhitespace: false).split

        XCTAssertEqual(rows.count, 6)
        guard case let .full(hunk) = rows[0] else { return XCTFail("Expected a hunk row") }
        XCTAssertEqual(hunk.kind, .hunk)
        guard case let .pair(contextLeft, contextRight) = rows[1] else { return XCTFail("Expected a context row") }
        XCTAssertEqual(contextLeft, contextRight)
        guard case let .pair(left, right) = rows[2] else { return XCTFail("Expected a change row") }
        XCTAssertEqual(left?.text, "b")
        XCTAssertEqual(right?.text, "B")
        guard case let .pair(onlyLeft, missingRight) = rows[3] else { return XCTFail("Expected a change row") }
        XCTAssertEqual(onlyLeft?.text, "c")
        XCTAssertNil(missingRight)
        guard case .full(let note) = rows[5] else { return XCTFail("Expected a note row") }
        XCTAssertEqual(note.kind, .note)
    }

    func testLongestCommonSubsequenceGivesUpOnHugeInputs() {
        XCTAssertNil(DiffPresentation.longestCommonSubsequence(["a", "b"], ["a", "b"], limit: 3))
        XCTAssertEqual(DiffPresentation.longestCommonSubsequence(["a", "b", "c"], ["a", "c"], limit: 10)?.map(\.0), [0, 2])
        XCTAssertEqual(DiffPresentation.longestCommonSubsequence([], ["a"], limit: 10)?.count, 0)
    }
}
