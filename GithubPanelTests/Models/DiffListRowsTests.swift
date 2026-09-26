import XCTest
@testable import GithubPanel

final class DiffListRowsTests: XCTestCase {
    private let patched = PullRequestFile(filename: "a.swift", previousFilename: nil, status: .modified,
                                          additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b")
    private let binary = PullRequestFile(filename: "logo.png", previousFilename: nil, status: .added,
                                         additions: 0, deletions: 0, patch: nil)

    func testUnifiedRowsWrapEachFilesLinesInHeaderAndFooter() {
        let rows = rows(mode: .unified)

        XCTAssertEqual(rows.map(\.id), ["a.swift", "a.swift#u0", "a.swift#u1", "a.swift#u2", "a.swift#footer",
                                        "logo.png", "logo.png#none", "logo.png#footer"])
        guard case let .unified(_, _, line) = rows[2] else { return XCTFail("Expected a unified line") }
        XCTAssertEqual(line.kind, .deletion)
    }

    func testSplitRowsPairDeletionsWithAdditions() {
        let rows = rows(mode: .split)

        XCTAssertEqual(rows.map(\.id).prefix(4), ["a.swift", "a.swift#s0", "a.swift#s1", "a.swift#footer"])
    }

    func testCollapsedFileShowsOnlyItsHeader() {
        XCTAssertEqual(rows(mode: .unified, collapsed: ["a.swift", "logo.png"]).map(\.id), ["a.swift", "logo.png"])
    }

    func testWhitespaceOnlyChangeShowsAMessage() {
        let file = PullRequestFile(filename: "w.swift", previousFilename: nil, status: .modified,
                                   additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-  a\n+a")

        let rows = DiffListRow.rows(files: [file], collapsed: [], mode: .unified, hideWhitespace: true) { _ in
            DiffPresentation(lines: DiffParser.parse(file.patch!), hideWhitespace: true)
        }

        XCTAssertEqual(rows, [.header(file), .message(filename: "w.swift", text: "Only whitespace changed."),
                              .footer(filename: "w.swift")])
    }

    func testRowIDsAreUniqueForLargeDiffs() {
        let patch = "@@ -1,500 +1,500 @@\n" + (0..<500).map { " line \($0)" }.joined(separator: "\n")
        let files = (0..<3).map { PullRequestFile(filename: "f\($0).swift", previousFilename: nil, status: .modified,
                                                  additions: 0, deletions: 0, patch: patch) }

        let rows = DiffListRow.rows(files: files, collapsed: [], mode: .unified, hideWhitespace: false) { _ in
            DiffPresentation(lines: DiffParser.parse(patch), hideWhitespace: false)
        }

        XCTAssertEqual(rows.count, 3 * (501 + 2))
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testSectionsGroupEachFilesRowsUnderItsHeader() {
        let sections = DiffListSection.sections(rows(mode: .unified))

        XCTAssertEqual(sections.map(\.id), ["a.swift", "logo.png"])
        XCTAssertEqual(sections.map(\.file), [patched, binary])
        XCTAssertEqual(sections[0].rows.map(\.id), ["a.swift#u0", "a.swift#u1", "a.swift#u2", "a.swift#footer"])
        XCTAssertEqual(sections[1].rows.map(\.id), ["logo.png#none", "logo.png#footer"])
    }

    func testCollapsedFileSectionHasNoRows() {
        let sections = DiffListSection.sections(rows(mode: .unified, collapsed: ["a.swift"]))

        XCTAssertEqual(sections.map(\.id), ["a.swift", "logo.png"])
        XCTAssertEqual(sections[0].rows, [])
        XCTAssertEqual(sections[1].rows.map(\.id), ["logo.png#none", "logo.png#footer"])
    }

    func testNoFilesMakeNoSections() {
        XCTAssertEqual(DiffListSection.sections([]), [])
    }

    private func rows(mode: DiffViewMode, collapsed: Set<String> = []) -> [DiffListRow] {
        DiffListRow.rows(files: [patched, binary], collapsed: collapsed, mode: mode, hideWhitespace: false) { filename in
            filename == "a.swift" ? DiffPresentation(lines: DiffParser.parse(self.patched.patch!), hideWhitespace: false) : nil
        }
    }
}

final class DiffListRowsCommentTests: XCTestCase {
    private let file = PullRequestFile(filename: "a.swift", previousFilename: nil, status: .modified,
                                       additions: 1, deletions: 1, patch: "@@ -1,2 +1,2 @@\n ctx\n-a\n+b")

    func testThreadsFollowTheirLineInUnifiedView() {
        let onAddition = thread("t1", line: 2, side: .right)
        let outdated = thread("t2", line: nil, side: .right)

        let rows = rows(mode: .unified, threads: [onAddition, outdated])

        XCTAssertEqual(rows.map(\.id), ["a.swift", "a.swift#u0", "a.swift#u1", "a.swift#u2", "a.swift#u3", "a.swift#c3",
                                        "a.swift#unplaced", "a.swift#footer"])
        XCTAssertEqual(rows[5], .lineComments(filename: "a.swift", index: 3, threads: [onAddition], composing: nil))
        XCTAssertEqual(rows[6], .unplacedThreads(filename: "a.swift", threads: [outdated]))
    }

    func testOpenComposerAddsACommentRowInSplitView() {
        let anchor = DiffCommentAnchor(path: "a.swift", line: 2, side: .left)

        let rows = rows(mode: .split, threads: [], composing: anchor)

        // Hunk, context pair, then the deletion/addition pair with the composer on its left half.
        XCTAssertEqual(rows.map(\.id), ["a.swift", "a.swift#s0", "a.swift#s1", "a.swift#s2", "a.swift#c2", "a.swift#footer"])
        XCTAssertEqual(rows[4], .lineComments(filename: "a.swift", index: 2, threads: [], composing: anchor))
    }

    func testContextLineThreadsAreListedOnceInSplitView() {
        let onContext = thread("t", line: 1, side: .right)

        let rows = rows(mode: .split, threads: [onContext])

        XCTAssertEqual(rows.filter { if case .lineComments = $0 { return true } else { return false } },
                       [.lineComments(filename: "a.swift", index: 1, threads: [onContext], composing: nil)])
    }

    func testFileWithoutDiffListsAllThreadsAsUnplaced() {
        let binary = PullRequestFile(filename: "logo.png", previousFilename: nil, status: .added,
                                     additions: 0, deletions: 0, patch: nil)
        let onBinary = ReviewThread(id: "t", path: "logo.png", line: 1, startLine: nil, side: .right,
                                    isResolved: false, isOutdated: false, comments: [])

        let rows = DiffListRow.rows(files: [binary], collapsed: [], mode: .unified, hideWhitespace: false,
                                    threads: { _ in ReviewThreadIndex(threads: [onBinary]) }) { _ in nil }

        XCTAssertEqual(rows.map(\.id), ["logo.png", "logo.png#none", "logo.png#unplaced", "logo.png#footer"])
    }

    private func rows(mode: DiffViewMode, threads: [ReviewThread], composing: DiffCommentAnchor? = nil) -> [DiffListRow] {
        DiffListRow.rows(files: [file], collapsed: [], mode: mode, hideWhitespace: false,
                         threads: { _ in ReviewThreadIndex(threads: threads) }, composing: composing) { _ in
            DiffPresentation(lines: DiffParser.parse(self.file.patch!), hideWhitespace: false)
        }
    }

    private func thread(_ id: String, line: Int?, side: DiffSide) -> ReviewThread {
        ReviewThread(id: id, path: "a.swift", line: line, startLine: nil, side: side,
                     isResolved: false, isOutdated: line == nil, comments: [])
    }
}
