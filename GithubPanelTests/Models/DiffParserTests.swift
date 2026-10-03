import XCTest
@testable import GithubPanel

final class DiffParserTests: XCTestCase {
    func testParsesHunkWithLineNumbers() {
        let patch = """
        @@ -10,4 +10,5 @@ struct Widget {
             let name: String
        -    let size: Int
        +    let width: Int
        +    let height: Int
             let color: Color
        """

        let lines = DiffParser.parse(patch)

        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .deletion, .addition, .addition, .context])
        XCTAssertEqual(lines[0].text, "@@ -10,4 +10,5 @@ struct Widget {")
        XCTAssertEqual(lines[1], DiffLine(kind: .context, text: "    let name: String", oldLineNumber: 10, newLineNumber: 10))
        XCTAssertEqual(lines[2], DiffLine(kind: .deletion, text: "    let size: Int", oldLineNumber: 11, newLineNumber: nil))
        XCTAssertEqual(lines[3], DiffLine(kind: .addition, text: "    let width: Int", oldLineNumber: nil, newLineNumber: 11))
        XCTAssertEqual(lines[4], DiffLine(kind: .addition, text: "    let height: Int", oldLineNumber: nil, newLineNumber: 12))
        XCTAssertEqual(lines[5], DiffLine(kind: .context, text: "    let color: Color", oldLineNumber: 12, newLineNumber: 13))
    }

    func testRestartsLineNumbersAtEachHunk() {
        let patch = """
        @@ -1,2 +1,2 @@
        -a
        +b
        @@ -40 +40,2 @@
         c
        +d
        """

        let lines = DiffParser.parse(patch)

        XCTAssertEqual(lines[4], DiffLine(kind: .context, text: "c", oldLineNumber: 40, newLineNumber: 40))
        XCTAssertEqual(lines[5], DiffLine(kind: .addition, text: "d", oldLineNumber: nil, newLineNumber: 41))
    }

    func testKeepsNoNewlineMarkerAndIgnoresTrailingNewline() {
        let patch = "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n"

        let lines = DiffParser.parse(patch)

        XCTAssertEqual(lines.map(\.kind), [.hunk, .deletion, .note, .addition])
        XCTAssertEqual(lines[2].text, "\\ No newline at end of file")
        XCTAssertEqual(lines[3].newLineNumber, 1)
    }

    func testEmptyContextLineKeepsLineNumbers() {
        let patch = "@@ -5,3 +5,3 @@\n a\n\n b"

        let lines = DiffParser.parse(patch)

        XCTAssertEqual(lines[2], DiffLine(kind: .context, text: "", oldLineNumber: 6, newLineNumber: 6))
        XCTAssertEqual(lines[3].oldLineNumber, 7)
    }

    func testEmptyPatchHasNoLines() {
        XCTAssertEqual(DiffParser.parse(""), [])
    }

    func testHunkStartReadsSingleLineRanges() {
        XCTAssertEqual(DiffParser.hunkStart("@@ -0,0 +1 @@")?.old, 0)
        XCTAssertEqual(DiffParser.hunkStart("@@ -0,0 +1 @@")?.new, 1)
        XCTAssertNil(DiffParser.hunkStart("@@ garbage"))
    }

    func testSplitsARawDiffIntoEachFilesPatch() {
        let rawDiff = """
        diff --git a/Sources/Big.swift b/Sources/Big.swift
        index 1111111..2222222 100644
        --- a/Sources/Big.swift
        +++ b/Sources/Big.swift
        @@ -1,2 +1,2 @@
         let a = 1
        -let b = 2
        +let b = 3
        @@ -10 +10 @@
        -old
        +new
        diff --git a/logo.png b/logo.png
        new file mode 100644
        index 0000000..3333333
        Binary files /dev/null and b/logo.png differ
        diff --git a/Old.swift b/Renamed.swift
        similarity index 100%
        rename from Old.swift
        rename to Renamed.swift
        diff --git a/Gone.swift b/Gone.swift
        deleted file mode 100644
        index 4444444..0000000
        --- a/Gone.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye

        """

        let patches = DiffParser.patchesByFile(rawDiff: rawDiff)

        XCTAssertEqual(patches, [
            "Sources/Big.swift": "@@ -1,2 +1,2 @@\n let a = 1\n-let b = 2\n+let b = 3\n@@ -10 +10 @@\n-old\n+new",
            "Gone.swift": "@@ -1 +0,0 @@\n-bye"
        ])
    }
}
