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

    // MARK: - Reviews

    func testAReviewShowsInTheActivityListAndReviewersAsTheViewers() throws {
        let requested = withReviewers([PullRequestReviewer(name: "Monalisa", kind: .user, state: .pending,
                                                           isCodeOwner: true)], entryWithComments())
        let review = change(.review(NewPullRequestReview(event: .requestChanges, body: "Add tests", commitID: "sha-7"),
                                    authorLogin: "monalisa"))

        let shown = PendingChange.apply(review, to: requested)

        let item = try XCTUnwrap(shown.comments?.reviews.last)
        XCTAssertEqual(item.body, "Add tests")
        XCTAssertEqual(item.authorLogin, "monalisa")
        XCTAssertEqual(item.reviewState, .changesRequested)
        XCTAssertEqual(item.pendingChangeID, review.id)
        XCTAssertEqual(shown.comments?.timeline.last?.id, item.id, "Shows after the loaded comments")
        XCTAssertEqual(shown.content.detail.reviewers.reviewers,
                       [PullRequestReviewer(name: "Monalisa", kind: .user, state: .changesRequested, isCodeOwner: true)],
                       "The review answers the request")
    }

    func testAPlainCommentReviewKeepsAnEarlierVerdictAndAnUnknownViewerChangesNoReviewer() {
        let approved = withReviewers([PullRequestReviewer(name: "monalisa", kind: .user, state: .approved)], entry())
        let comment = NewPullRequestReview(event: .comment, body: "Nit", commitID: "sha-7")

        XCTAssertEqual(PendingChange.apply(change(.review(comment, authorLogin: "monalisa")), to: approved)
                        .content.detail.reviewers.reviewers.map(\.state), [.approved])
        XCTAssertEqual(PendingChange.apply(change(.review(comment, authorLogin: nil)), to: entry())
                        .content.detail.reviewers, entry().content.detail.reviewers)
    }

    func testAReviewGitHubsCopyAlreadyHasShowsOnce() {
        var posted = change(.review(NewPullRequestReview(event: .approve, body: "", commitID: "sha-7"),
                                    authorLogin: "monalisa"))
        posted.postedCommentID = 80
        var withReview = entryWithComments()
        withReview.comments = withReview.comments?.adding(review: PullRequestComment(
            id: "PRR_80", databaseID: 80, authorLogin: "monalisa", body: "", createdAt: Date(), htmlURL: nil,
            reviewState: .approved))

        XCTAssertEqual(PendingChange.apply(posted, to: withReview).comments?.reviews.map(\.id), ["PRR_80"])
    }

    func testAStartedReviewIsPendingBeforeTheCommentsReloadWithIt() {
        let starting = change(.startReview(pullRequestID: "PR_node", commitID: "sha-7", reviewID: nil))
        let started = change(.startReview(pullRequestID: "PR_node", commitID: "sha-7", reviewID: "PRR_1"))

        XCTAssertNil(PendingChange.apply(starting, to: entryWithComments()).comments?.pendingReviewID)
        XCTAssertEqual(PendingChange.apply(started, to: entryWithComments()).comments?.pendingReviewID, "PRR_1")
    }

    func testADraftShowsInItsPlaceAsPendingAndTheViewers() throws {
        let anchor = DiffCommentAnchor(path: "a.swift", line: 9, side: .left)
        let thread = change(.reviewComment(.thread(body: "Why?", anchor: anchor), review: .review(id: "PRR_1"),
                                           authorLogin: "monalisa"))
        let reply = change(.reviewComment(.reply(body: "Agreed", threadID: "t1"), review: .review(id: "PRR_1"),
                                          authorLogin: "monalisa"))

        let shown = try XCTUnwrap(PendingChange.apply([thread, reply], to: entryWithComments()).comments)

        XCTAssertEqual(shown.threads.first?.comments.map(\.body), ["Why?", "Agreed"])
        XCTAssertEqual(shown.threads.first?.comments.last?.isPending, true)
        let newThread = try XCTUnwrap(shown.threads.last)
        XCTAssertEqual(newThread.anchor, anchor)
        XCTAssertTrue(newThread.isPending)
        XCTAssertEqual(newThread.comments.first?.authorLogin, "monalisa")
        XCTAssertEqual(newThread.comments.first?.pendingChangeID, thread.id)
        XCTAssertEqual(shown.pendingCommentCount, 2)
    }

    func testSubmittingThePendingReviewPublishesItsDraftsAndShowsTheReview() throws {
        let draft = change(.reviewComment(.reply(body: "Why?", threadID: "t1"), review: .review(id: "PRR_1"),
                                          authorLogin: "monalisa"))
        let submit = change(.submitPendingReview(review: .review(id: "PRR_1"), event: .approve, body: "",
                                                 authorLogin: "monalisa"))
        var pending = entryWithComments()
        pending.comments = pending.comments?.settingPendingReviewID("PRR_1")

        let shown = PendingChange.apply([draft, submit], to: pending)

        XCTAssertNil(shown.comments?.pendingReviewID)
        XCTAssertEqual(shown.comments?.pendingCommentCount, 0)
        XCTAssertEqual(shown.comments?.reviews.map(\.reviewState), [.approved])
        XCTAssertEqual(shown.content.detail.reviewers.reviewers.map(\.state), [.approved])
    }

    func testDiscardingThePendingReviewHidesItsDraftsAndTheirThreads() throws {
        let anchor = DiffCommentAnchor(path: "a.swift", line: 9, side: .left)
        let thread = change(.reviewComment(.thread(body: "Why?", anchor: anchor), review: .review(id: "PRR_1"),
                                           authorLogin: nil))
        let reply = change(.reviewComment(.reply(body: "Agreed", threadID: "t1"), review: .review(id: "PRR_1"),
                                          authorLogin: nil))
        var pending = entryWithComments()
        pending.comments = pending.comments?.settingPendingReviewID("PRR_1")

        let shown = try XCTUnwrap(PendingChange.apply([thread, reply, change(.discardPendingReview(
            review: .review(id: "PRR_1")))], to: pending).comments)

        XCTAssertNil(shown.pendingReviewID)
        XCTAssertEqual(shown.threads.map(\.id), ["t1"])
        XCTAssertEqual(shown.threads.first?.comments.map(\.body), ["Why?"], "Keeps the published comment")
        XCTAssertEqual(shown.totalThreadCount, 5)
    }

    func testOnlyDiscardingAPendingReviewIsSentAgainAfterARestart() {
        let review = NewPullRequestReview(event: .approve, body: "", commitID: "sha")
        let kinds: [PendingChange.Kind] = [
            .review(review, authorLogin: nil),
            .startReview(pullRequestID: "PR", commitID: "sha", reviewID: nil),
            .reviewComment(.reply(body: "a", threadID: "t"), review: .review(id: "PRR"), authorLogin: nil),
            .submitPendingReview(review: .review(id: "PRR"), event: .approve, body: "", authorLogin: nil),
        ]
        for kind in kinds {
            XCTAssertFalse(kind.isSafeToResend, kind.name)
            XCTAssertNil(kind.field, "\(kind.name) replaces nothing")
        }
        XCTAssertTrue(PendingChange.Kind.discardPendingReview(review: .review(id: "PRR")).isSafeToResend)
    }

    func testAChangeWaitingForAStartGoesToTheReviewItStarted() {
        let start = UUID()
        let kind = PendingChange.Kind.submitPendingReview(review: .startedBy(start), event: .comment, body: "b",
                                                          authorLogin: "me")

        XCTAssertEqual(kind.sending(toReview: "PRR_1"),
                       .submitPendingReview(review: .review(id: "PRR_1"), event: .comment, body: "b", authorLogin: "me"))
        XCTAssertEqual(kind.text, "b")
    }

    private func withReviewers(_ reviewers: [PullRequestReviewer],
                               _ entry: PullRequestDetailCache.Entry) -> PullRequestDetailCache.Entry {
        var entry = entry
        var detail = entry.content.detail
        detail.reviewers = PullRequestReviewers(reviewers: reviewers)
        entry.content = PullRequestDetailContent(detail: detail, files: entry.content.files)
        return entry
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
