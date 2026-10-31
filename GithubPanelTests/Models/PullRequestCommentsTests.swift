import XCTest
@testable import GithubPanel

final class PullRequestCommentsTests: XCTestCase {
    private let path = "Sources/Widget.swift"

    func testLimitsGrowByAStepEach() {
        let limits = PullRequestCommentLimits()
        XCTAssertEqual(limits, PullRequestCommentLimits(comments: 30, threads: 50))
        XCTAssertEqual(limits.addingEarlierComments(), PullRequestCommentLimits(comments: 60, threads: 50))
        XCTAssertEqual(limits.addingThreads().addingThreads(), PullRequestCommentLimits(comments: 30, threads: 150))
    }

    func testUnloadedCountsComeFromTheTotals() {
        let comment = PullRequestComment(id: "c", databaseID: 1, authorLogin: "a", body: "", createdAt: Date(), htmlURL: nil)
        let partial = PullRequestComments(comments: [comment], threads: [], totalCommentCount: 40, totalThreadCount: 7)
        XCTAssertEqual(partial.earlierCommentCount, 39)
        XCTAssertEqual(partial.unloadedThreadCount, 7)

        // Without totals, or with totals below what loaded, everything counts as loaded.
        XCTAssertEqual(PullRequestComments(comments: [comment], threads: []).earlierCommentCount, 0)
        XCTAssertEqual(PullRequestComments(comments: [comment], threads: [], totalCommentCount: 0).totalCommentCount, 1)
    }

    func testUnifiedAnchorPutsDeletionsOnTheOldSide() {
        XCTAssertEqual(DiffCommentAnchor.unified(path: path, line: line(.deletion, old: 4, new: nil)),
                       DiffCommentAnchor(path: path, line: 4, side: .left))
        XCTAssertEqual(DiffCommentAnchor.unified(path: path, line: line(.addition, old: nil, new: 5)),
                       DiffCommentAnchor(path: path, line: 5, side: .right))
        XCTAssertEqual(DiffCommentAnchor.unified(path: path, line: line(.context, old: 3, new: 7)),
                       DiffCommentAnchor(path: path, line: 7, side: .right))
        XCTAssertNil(DiffCommentAnchor.unified(path: path, line: line(.hunk, old: nil, new: nil)))
        XCTAssertNil(DiffCommentAnchor.unified(path: path, line: line(.note, old: nil, new: nil)))
    }

    func testSplitAnchorUsesTheHalfSide() {
        let context = line(.context, old: 3, new: 7)

        XCTAssertEqual(DiffCommentAnchor.split(path: path, line: context, side: .left),
                       DiffCommentAnchor(path: path, line: 3, side: .left))
        XCTAssertEqual(DiffCommentAnchor.split(path: path, line: context, side: .right),
                       DiffCommentAnchor(path: path, line: 7, side: .right))
        XCTAssertNil(DiffCommentAnchor.split(path: path, line: nil, side: .left))
        XCTAssertNil(DiffCommentAnchor.split(path: path, line: line(.hunk, old: nil, new: nil), side: .right))
    }

    func testIndexPlacesThreadsUnderTheirLines() {
        let onAddition = thread("a", line: 5, side: .right)
        let onDeletion = thread("b", line: 4, side: .left)
        let onContextOld = thread("c", line: 3, side: .left)
        let onContextNew = thread("d", line: 7, side: .right)
        let index = ReviewThreadIndex(threads: [onAddition, onDeletion, onContextOld, onContextNew])

        XCTAssertEqual(index.threads(for: line(.addition, old: nil, new: 5), path: path), [onAddition])
        XCTAssertEqual(index.threads(for: line(.deletion, old: 4, new: nil), path: path), [onDeletion])
        XCTAssertEqual(index.threads(for: line(.context, old: 3, new: 7), path: path), [onContextOld, onContextNew])
        // A deletion on old line 5 is not the new file's line 5.
        XCTAssertEqual(index.threads(for: line(.deletion, old: 5, new: nil), path: path), [])
        XCTAssertEqual(index.threads(at: DiffCommentAnchor(path: path, line: 5, side: .right)), [onAddition])
        XCTAssertEqual(index.threads(at: nil), [])
    }

    func testUnplacedThreadsIncludeOutdatedAndMissingLines() {
        let shown = thread("shown", line: 5, side: .right)
        let outdated = thread("outdated", line: nil, side: .right)
        let offDiff = thread("off", line: 90, side: .right)
        let index = ReviewThreadIndex(threads: [shown, outdated, offDiff])

        let unplaced = index.unplacedThreads(in: [line(.hunk, old: nil, new: nil), line(.addition, old: nil, new: 5)],
                                             path: path)

        XCTAssertEqual(unplaced, [outdated, offDiff])
        XCTAssertEqual(index.unplacedThreads(in: [], path: path), [shown, outdated, offDiff])
    }

    private func line(_ kind: DiffLine.Kind, old: Int?, new: Int?) -> DiffDisplayLine {
        DiffDisplayLine(kind: kind, oldLineNumber: old, newLineNumber: new,
                        segments: [DiffSegment(text: "x", isChanged: false)])
    }

    private func thread(_ id: String, line: Int?, side: DiffSide) -> ReviewThread {
        ReviewThread(id: id, path: path, line: line, startLine: nil, side: side,
                     isResolved: false, isOutdated: line == nil, comments: [])
    }
}
