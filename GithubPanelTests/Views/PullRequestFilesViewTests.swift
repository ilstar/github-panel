import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

final class PullRequestFilesViewTests: XCTestCase {
    func testDisplayNameShowsRenames() {
        XCTAssertEqual(PullRequestFileHeader.displayName(file(filename: "New.swift", previousFilename: "Old.swift")),
                       "Old.swift → New.swift")
        XCTAssertEqual(PullRequestFileHeader.displayName(file(filename: "Same.swift", previousFilename: nil)),
                       "Same.swift")
    }

    func testStatusLabels() {
        XCTAssertEqual(PullRequestFileHeader.statusLabel(.removed), "DELETED")
        XCTAssertEqual(PullRequestFileHeader.statusLabel(.changed), "MODIFIED")
    }

    func testCopyPathPutsFilenameOnPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GithubPanelTests.copyPath.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("stale", forType: .string)

        PullRequestFileHeader.copyPath("Sources/New.swift", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "Sources/New.swift")
    }

    func testAttributedTextFillsOnlyChangedWords() {
        let line = DiffDisplayLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, segments: [
            DiffSegment(text: "hello ", isChanged: false),
            DiffSegment(text: "claude", isChanged: true)
        ])

        let text = DiffColors.attributedText(line)

        XCTAssertEqual(String(text.characters), "hello claude")
        let highlighted = text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
        XCTAssertEqual(highlighted, ["claude"])
    }

    func testAttributedTextKeepsEmptyLinesVisible() {
        let line = DiffDisplayLine(kind: .context, oldLineNumber: 1, newLineNumber: 1,
                                   segments: [DiffSegment(text: "", isChanged: false)])

        XCTAssertEqual(String(DiffColors.attributedText(line).characters), " ")
    }

    private func file(filename: String, previousFilename: String?) -> PullRequestFile {
        PullRequestFile(filename: filename,
                        previousFilename: previousFilename,
                        status: previousFilename == nil ? .modified : .renamed,
                        additions: 0,
                        deletions: 0,
                        patch: nil)
    }
}
