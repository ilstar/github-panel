import XCTest
@testable import GithubPanel

final class PendingChangeTests: XCTestCase {
    private let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)

    func testATitleChangeSetsOnlyTheTitle() {
        let shown = PendingChange.apply(change(.title("New")), to: entry())

        XCTAssertEqual(shown.content.detail.title, "New")
        XCTAssertEqual(shown.content.detail.body, "Old body")
        XCTAssertEqual(shown.content.files, entry().content.files)
    }

    func testABodyChangeSetsTheWholeDescription() {
        let shown = PendingChange.apply(change(.body("- [x] done")), to: entry())

        XCTAssertEqual(shown.content.detail.body, "- [x] done")
        XCTAssertEqual(shown.content.detail.title, "Old")
    }

    func testAViewedChangeMarksOnlyThatFile() {
        let viewed = PendingChange.apply(change(.fileViewed(pullRequestID: "PR_node", path: "b.swift", viewed: true)),
                                         to: entry())
        let unviewed = PendingChange.apply(change(.fileViewed(pullRequestID: "PR_node", path: "a.swift", viewed: false)),
                                           to: entry())

        XCTAssertEqual(viewed.content.files.filter(\.isViewed).map(\.filename), ["a.swift", "b.swift"])
        XCTAssertEqual(unviewed.content.files.filter(\.isViewed).map(\.filename), [])
    }

    func testAResolveChangeSetsOnlyThatThread() {
        let shown = PendingChange.apply(change(.threadResolved(threadID: "t1", resolved: true)), to: entry())

        XCTAssertEqual(shown.comments?.threads.map(\.isResolved), [true, false])
        XCTAssertEqual(shown.comments?.totalThreadCount, 5, "Keeps what else the comments say")
    }

    func testAResolveChangeBeforeTheCommentsLoadShowsNothing() {
        var noComments = entry()
        noComments.comments = nil

        XCTAssertNil(PendingChange.apply(change(.threadResolved(threadID: "t1", resolved: true)), to: noComments).comments)
    }

    func testAReviewRequestChangeAddsOrRemovesTheReviewer() {
        let requested = PendingChange.apply(change(.reviewRequested(name: "hubot", kind: .user, requested: true)),
                                            to: entry())
        let removed = PendingChange.apply(change(.reviewRequested(name: "hubot", kind: .user, requested: false)),
                                          to: requested)

        XCTAssertTrue(requested.content.detail.reviewers.isRequested("user:hubot"))
        XCTAssertFalse(removed.content.detail.reviewers.isRequested("user:hubot"))
    }

    func testAGeneralCommentShowsAfterTheLoadedOnesAsTheViewersAndCounts() throws {
        let posting = change(.comment(.general(body: "Looks good"), authorLogin: "monalisa"))

        let shown = try XCTUnwrap(PendingChange.apply(posting, to: entryWithComments()).comments)

        XCTAssertEqual(shown.comments.map(\.body), ["First", "Looks good"])
        let added = try XCTUnwrap(shown.comments.last)
        XCTAssertEqual(added.authorLogin, "monalisa")
        XCTAssertEqual(added.pendingChangeID, posting.id)
        XCTAssertEqual(added.createdAt, posting.createdAt)
        XCTAssertEqual(shown.totalCommentCount, 11)
        XCTAssertEqual(shown.threads, entryWithComments().comments?.threads)
    }

    func testAReplyShowsAtTheEndOfItsThread() throws {
        let replying = change(.comment(.reply(body: "Fixed", commentID: 41), authorLogin: "monalisa"))
        let elsewhere = change(.comment(.reply(body: "Lost", commentID: 999), authorLogin: "monalisa"))

        let shown = try XCTUnwrap(PendingChange.apply(replying, to: entryWithComments()).comments)
        let unloaded = PendingChange.apply(elsewhere, to: entryWithComments()).comments

        XCTAssertEqual(shown.threads.map { $0.comments.map(\.body) }, [["Why?", "Fixed"]])
        XCTAssertEqual(shown.threads.first?.comments.last?.pendingChangeID, replying.id)
        XCTAssertEqual(shown.comments, entryWithComments().comments?.comments)
        XCTAssertEqual(unloaded, entryWithComments().comments, "A reply to a thread that isn't loaded shows nothing")
    }

    func testAnInlineCommentStartsAThreadOnItsLine() throws {
        let anchor = DiffCommentAnchor(path: "b.swift", line: 9, side: .left)
        let commenting = change(.comment(.inline(body: "Why?", commitID: "sha-7", anchor: anchor), authorLogin: "monalisa"))

        let shown = try XCTUnwrap(PendingChange.apply(commenting, to: entryWithComments()).comments)

        let thread = try XCTUnwrap(shown.threads.last)
        XCTAssertEqual(thread.anchor, anchor)
        XCTAssertFalse(thread.isOutdated)
        XCTAssertEqual(thread.comments.map(\.body), ["Why?"])
        XCTAssertEqual(thread.comments.first?.pendingChangeID, commenting.id)
        XCTAssertEqual(shown.totalThreadCount, 6)
        XCTAssertEqual(shown.unloadedThreadCount, 4)
    }

    func testAnInlineCommentOnAnOlderHeadShowsOutdatedRatherThanOnALine() throws {
        let anchor = DiffCommentAnchor(path: "b.swift", line: 9, side: .right)
        let commenting = change(.comment(.inline(body: "Why?", commitID: "old-sha", anchor: anchor), authorLogin: nil))

        let thread = try XCTUnwrap(PendingChange.apply(commenting, to: entryWithComments()).comments?.threads.last)

        XCTAssertTrue(thread.isOutdated)
        XCTAssertNil(thread.anchor, "Not moved onto a line of the new diff")
        XCTAssertEqual(thread.path, "b.swift")
        XCTAssertEqual(thread.comments.first?.authorLogin, "", "Shown as You until the viewer's login loads")
    }

    func testACommentGitHubsCopyAlreadyHasShowsOnce() {
        var posted = change(.comment(.general(body: "First"), authorLogin: "monalisa"))
        posted.postedCommentID = 1
        var reply = change(.comment(.reply(body: "Why?", commentID: 41), authorLogin: "monalisa"))
        reply.postedCommentID = 41

        XCTAssertEqual(PendingChange.apply([posted, reply], to: entryWithComments()), entryWithComments())
    }

    func testACommentBeforeTheCommentsLoadShowsNothing() {
        var noComments = entry()
        noComments.comments = nil

        XCTAssertNil(PendingChange.apply(change(.comment(.general(body: "Hi"), authorLogin: nil)), to: noComments).comments)
    }

    func testCommentsAreNotSentAgainAfterARestartAndReplaceNothing() {
        let comment = PendingChange.Kind.comment(.general(body: "Hi"), authorLogin: nil)

        XCTAssertFalse(comment.isSafeToResend)
        XCTAssertNil(comment.field)
        XCTAssertTrue(PendingChange.Kind.title("a").isSafeToResend)
    }

    func testChangesApplyInOrderSoTheLastToAFieldWins() {
        let shown = PendingChange.apply([change(.body("First")), change(.title("New")), change(.body("Second"))],
                                        to: entry())

        XCTAssertEqual(shown.content.detail.body, "Second")
        XCTAssertEqual(shown.content.detail.title, "New")
    }

    func testChangesToTheSameThingShareAField() {
        XCTAssertEqual(PendingChange.Kind.body("a").field, PendingChange.Kind.body("b").field)
        XCTAssertEqual(PendingChange.Kind.fileViewed(pullRequestID: "PR", path: "a", viewed: true).field,
                       PendingChange.Kind.fileViewed(pullRequestID: "PR", path: "a", viewed: false).field)
        XCTAssertNotEqual(PendingChange.Kind.fileViewed(pullRequestID: "PR", path: "a", viewed: true).field,
                          PendingChange.Kind.fileViewed(pullRequestID: "PR", path: "b", viewed: true).field)
        XCTAssertEqual(PendingChange.Kind.reviewRequested(name: "Hubot", kind: .user, requested: true).field,
                       PendingChange.Kind.reviewRequested(name: "hubot", kind: .user, requested: false).field)
        XCTAssertNotEqual(PendingChange.Kind.title("a").field, PendingChange.Kind.body("a").field)
    }

    private func change(_ kind: PendingChange.Kind) -> PendingChange {
        PendingChange(reference: reference, kind: kind)
    }

    /// One general comment of ten, and one thread of five, started by the comment with REST ID 41.
    private func entryWithComments() -> PullRequestDetailCache.Entry {
        func comment(_ id: Int, _ body: String) -> PullRequestComment {
            PullRequestComment(id: "c\(id)", databaseID: id, authorLogin: "octocat", body: body,
                               createdAt: Date(timeIntervalSince1970: 0), htmlURL: nil)
        }
        var entry = entry()
        entry.comments = PullRequestComments(
            comments: [comment(1, "First")],
            threads: [ReviewThread(id: "t1", path: "a.swift", line: 1, startLine: nil, side: .right, isResolved: false,
                                   isOutdated: false, comments: [comment(41, "Why?")])],
            totalCommentCount: 10, totalThreadCount: 5)
        return entry
    }

    private func entry() -> PullRequestDetailCache.Entry {
        let content = detailContent(for: reference, title: "Old")
        var detail = content.detail
        detail.body = "Old body"
        let files = [
            PullRequestFile(filename: "a.swift", previousFilename: nil, status: .modified,
                            additions: 1, deletions: 0, patch: nil, isViewed: true),
            PullRequestFile(filename: "b.swift", previousFilename: nil, status: .modified,
                            additions: 1, deletions: 0, patch: nil),
        ]
        let threads = ["t1", "t2"].map { id in
            ReviewThread(id: id, path: "a.swift", line: 1, startLine: nil, side: .right, isResolved: false,
                         isOutdated: false, comments: [])
        }
        return PullRequestDetailCache.Entry(content: PullRequestDetailContent(detail: detail, files: files),
                                            comments: PullRequestComments(comments: [], threads: threads,
                                                                          totalThreadCount: 5))
    }
}
