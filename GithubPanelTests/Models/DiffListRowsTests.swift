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

    private func rows(mode: DiffViewMode, collapsed: Set<String> = []) -> [DiffListRow] {
        DiffListRow.rows(files: [patched, binary], collapsed: collapsed, mode: mode, hideWhitespace: false) { filename in
            filename == "a.swift" ? DiffPresentation(lines: DiffParser.parse(self.patched.patch!), hideWhitespace: false) : nil
        }
    }
}
