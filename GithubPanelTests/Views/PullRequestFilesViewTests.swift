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

    func testShieldIdentifiesTeamAndIndividualOwners() {
        XCTAssertEqual(CodeOwnerShield.ownerLabel("@acme/platform"), "Team @acme/platform")
        XCTAssertEqual(CodeOwnerShield.ownerLabel("@alice"), "@alice")
        XCTAssertEqual(CodeOwnerShield.ownerLabel("alice@example.com"), "alice@example.com")
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

    /// Lines ignore the pointer while the diff scrolls, which needs a monitor on the diff list's own scroll view.
    @MainActor
    func testDiffListMonitorsItsOwnScrolling() async throws {
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)
        let files = [PullRequestFile(filename: "Sources/A.swift", previousFilename: nil, status: .modified,
                                     additions: 1, deletions: 0, patch: "@@ -1 +1,2 @@\n a\n+b",
                                     codeOwners: ["@acme/platform"], isOwnedByViewer: true)]
        let content = PullRequestDetailContent(detail: detailContent(for: reference).detail, files: files)
        let viewModel = PullRequestDetailViewModel(reference: reference) { _ in content }
        await viewModel.load()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PullRequestFilesView(viewModel: viewModel, files: files,
                                                                filesURL: content.detail.htmlURL))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        // The diff list is the widest scroll view; the file tree beside it is narrower.
        let diffList = try XCTUnwrap(Self.descendants(of: host).compactMap { $0 as? NSScrollView }
            .max { $0.frame.width < $1.frame.width })
        let monitors = Self.descendants(of: host).compactMap { $0 as? ScrollActivityMonitor.MonitorView }
        XCTAssertEqual(monitors.map(\.enclosingScrollView), [diffList])
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
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
