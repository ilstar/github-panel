import SwiftUI
import XCTest
@testable import GithubPanel

final class PullRequestCommentViewsTests: XCTestCase {
    func testCommentAuthorUsesProfileNameWithLoginAndViewerFallbacks() throws {
        var comment = PullRequestComment(id: "c", databaseID: 1, authorLogin: "octocat", body: "Hi",
                                         createdAt: Date(timeIntervalSince1970: 0), htmlURL: nil)
        for name: String? in [nil, "", " \n "] {
            comment.authorName = name
            XCTAssertEqual(PullRequestCommentView.authorName(comment), "octocat")
        }
        comment.authorName = " Mona Lisa "
        XCTAssertEqual(PullRequestCommentView.authorName(comment), "Mona Lisa")
        XCTAssertEqual(comment.authorLogin, "octocat")
        let namedThread = thread(line: 1, startLine: nil).replacingComments([comment])
        XCTAssertEqual(ReviewThreadView.summary(namedThread), "Mona Lisa · 1 comment")
        XCTAssertEqual(try JSONDecoder().decode(PullRequestComment.self,
            from: JSONEncoder().encode(comment)), comment)
        comment.authorName = nil
        XCTAssertEqual(try JSONDecoder().decode(PullRequestComment.self,
            from: JSONEncoder().encode(comment)).authorDisplayName, "octocat")
        let unsent = PullRequestComment(id: "c", databaseID: 0, authorLogin: "", body: "Hi",
                                       createdAt: Date(), htmlURL: nil)
        XCTAssertEqual(PullRequestCommentView.authorName(unsent), "You")
    }

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

    func testResolveTitleFollowsTheThreadState() {
        let open = thread(line: 1, startLine: nil)
        let resolved = ReviewThread(id: open.id, path: open.path, line: open.line, startLine: nil, side: .right,
                                    isResolved: true, isOutdated: false, comments: open.comments)
        XCTAssertEqual(ReviewThreadView.resolveTitle(open), "Resolve conversation")
        XCTAssertEqual(ReviewThreadView.resolveTitle(resolved), "Unresolve conversation")
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

    func testLongCommentBodiesAreCapped() {
        typealias Body = CollapsibleCommentBody<EmptyView>
        let cap = Body.maxCollapsedHeight
        XCTAssertFalse(Body.isCapped(contentHeight: 0))
        XCTAssertFalse(Body.isCapped(contentHeight: cap))
        XCTAssertFalse(Body.isCapped(contentHeight: cap + Body.slack), "A body just past the cap shows in full")
        XCTAssertTrue(Body.isCapped(contentHeight: cap + Body.slack + 1))
        XCTAssertTrue(Body.isCapped(contentHeight: 5_000))
    }

    func testCapToggleTitleFollowsTheState() {
        XCTAssertEqual(CollapsibleCommentBody<EmptyView>.toggleTitle(isExpanded: false), "Expand")
        XCTAssertEqual(CollapsibleCommentBody<EmptyView>.toggleTitle(isExpanded: true), "Collapse")
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
