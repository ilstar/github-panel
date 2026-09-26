import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

/// Guards fast scrolling in Files changed. Each test scrolls the real diff list and a plain list of one text per
/// line through the same window, then compares the two. Comparing against a plain list in the same run keeps the
/// check about the diff rows themselves, not about how fast or busy the machine is.
@MainActor
final class DiffScrollPerformanceTests: XCTestCase {
    /// About one frame of a fast trackpad flick.
    private static let step: CGFloat = 120
    private static let steps = 100

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PullRequestFilesView.viewModeDefaultsKey)
        UserDefaults.standard.removeObject(forKey: PullRequestFilesView.showsFileTreeDefaultsKey)
        super.tearDown()
    }

    func testUnifiedDiffScrollsNearlyAsFastAsPlainText() async throws {
        let ratio = try await scrollCostRatio(mode: .unified)
        // Measured 3.2–3.3. Making every line selectable again gave 5.6; the four-text rows before #51 gave 6.6–6.8.
        XCTAssertLessThan(ratio, 4.5, "Unified diff rows are \(ratio)× slower to scroll than plain text rows")
    }

    func testSplitDiffScrollsNearlyAsFastAsPlainText() async throws {
        let ratio = try await scrollCostRatio(mode: .split)
        // Measured 3.6–3.7. Making every line selectable again gave 6.2; the four-text rows before #51 gave 6.5–6.6.
        XCTAssertLessThan(ratio, 4.5, "Split diff rows are \(ratio)× slower to scroll than plain text rows")
    }

    /// The diff list's median frame time over the plain list's. The two take turns three times and each keeps its
    /// fastest run, so a burst of other work on the machine does not fail the test.
    private func scrollCostRatio(mode: DiffViewMode) async throws -> Double {
        UserDefaults.standard.set(mode.rawValue, forKey: PullRequestFilesView.viewModeDefaultsKey)
        UserDefaults.standard.set(false, forKey: PullRequestFilesView.showsFileTreeDefaultsKey)
        let files = Self.files()
        let viewModel = PullRequestDetailViewModel(reference: Self.reference) { _ in Self.content(files) }
        await viewModel.load()
        let lines = files.flatMap { ($0.patch ?? "").components(separatedBy: "\n") }

        var diff = Double.infinity
        var plain = Double.infinity
        for _ in 0..<3 {
            diff = min(diff, try medianFrameTime(PullRequestFilesView(viewModel: viewModel, files: files,
                                                                      filesURL: Self.htmlURL)))
            plain = min(plain, try medianFrameTime(PlainLines(lines: lines)))
        }
        return diff / plain
    }

    /// Scrolls `view` down in fixed steps and returns the median time to lay out and draw each step, in seconds.
    private func medianFrameTime(_ view: some View) throws -> Double {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let scrollView = try XCTUnwrap(Self.scrollViews(in: host).max { $0.frame.width < $1.frame.width })
        let documentHeight = try XCTUnwrap(scrollView.documentView).frame.height
        XCTAssertGreaterThan(documentHeight, Self.step * CGFloat(Self.steps) + window.frame.height,
                             "The fixture is too short to scroll through every step")

        var times: [Double] = []
        for index in 1...Self.steps {
            let start = CACurrentMediaTime()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: Self.step * CGFloat(index)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            times.append(CACurrentMediaTime() - start)
        }
        return times.sorted()[times.count / 2]
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    /// The cheapest list of the same lines: one monospaced text per line.
    private struct PlainLines: View {
        let lines: [String]

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Fixture

    private static let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)
    private static let htmlURL = URL(string: "https://github.com/acme/widgets/pull/7")!

    /// Four files of Swift-like code, 400 lines each, with every seventh line changed so word highlights show. Lines
    /// are ordinary code length: long wrapping lines make text layout dominate and hide the cost of the row views.
    private static func files() -> [PullRequestFile] {
        (0..<4).map { fileIndex in
            var patch = "@@ -1,400 +1,400 @@ struct Example\(fileIndex) {\n"
            for lineIndex in 0..<400 {
                let indent = String(repeating: "    ", count: lineIndex % 4)
                let line = "\(indent)let value\(lineIndex) = compute(\"item-\(lineIndex)\", count: \(lineIndex * 3), "
                    + String(repeating: "flag: true, ", count: lineIndex % 3) + "name: \"example\")"
                if lineIndex % 7 == 3 {
                    patch += "-\(line)\n+\(line.replacingOccurrences(of: "let", with: "var")) // changed\n"
                } else {
                    patch += " \(line)\n"
                }
            }
            return PullRequestFile(filename: "Sources/Example\(fileIndex).swift", previousFilename: nil,
                                   status: .modified, additions: 58, deletions: 58, patch: patch)
        }
    }

    private static func content(_ files: [PullRequestFile]) -> PullRequestDetailContent {
        PullRequestDetailContent(
            detail: PullRequestDetail(reference: reference, nodeID: "PR_node", title: "Example", body: "",
                                      authorLogin: "octocat", state: .open, baseRef: "main", headRef: "feature",
                                      headSHA: "abc123", htmlURL: htmlURL,
                                      createdAt: Date(timeIntervalSince1970: 0), additions: 232, deletions: 232,
                                      changedFiles: files.count, commits: 1),
            files: files)
    }
}
