import XCTest
@testable import GithubPanel

final class PullRequestCommentViewsTests: XCTestCase {
    func testThreadTitleNamesTheFileAndLines() {
        XCTAssertEqual(ReviewThreadView.title(thread(line: 12, startLine: nil)), "Widget.swift line 12")
        XCTAssertEqual(ReviewThreadView.title(thread(line: 12, startLine: 10)), "Widget.swift lines 10–12")
        XCTAssertEqual(ReviewThreadView.title(thread(line: 12, startLine: 12)), "Widget.swift line 12")
        XCTAssertEqual(ReviewThreadView.title(thread(line: nil, startLine: nil)), "Widget.swift")
    }

    func testThreadSummaryCountsComments() {
        XCTAssertEqual(ReviewThreadView.summary(thread(line: 1, startLine: nil, commentCount: 1)), "octocat · 1 comment")
        XCTAssertEqual(ReviewThreadView.summary(thread(line: 1, startLine: nil, commentCount: 3)), "octocat · 3 comments")
        XCTAssertEqual(ReviewThreadView.summary(thread(line: 1, startLine: nil, commentCount: 0)), "0 comments")
    }

    func testComposerTrimsTheDraft() {
        XCTAssertEqual(CommentComposer.trimmed("  Looks good\n\n"), "Looks good")
        XCTAssertEqual(CommentComposer.trimmed(" \n "), "")
    }

    func testComposerPlaceholderNamesTheSide() {
        XCTAssertEqual(PullRequestFilesView.composerPlaceholder(DiffCommentAnchor(path: "a", line: 4, side: .left)),
                       "Comment on old line 4…")
        XCTAssertEqual(PullRequestFilesView.composerPlaceholder(DiffCommentAnchor(path: "a", line: 5, side: .right)),
                       "Comment on line 5…")
    }

    private func thread(line: Int?, startLine: Int?, commentCount: Int = 1) -> ReviewThread {
        let comments = (0..<commentCount).map { index in
            PullRequestComment(id: "c\(index)", databaseID: index, authorLogin: "octocat", body: "Hi",
                               createdAt: Date(timeIntervalSince1970: 0), htmlURL: nil)
        }
        return ReviewThread(id: "t", path: "Sources/Widget.swift", line: line, startLine: startLine, side: .right,
                            isResolved: false, isOutdated: line == nil, comments: comments)
    }
}
