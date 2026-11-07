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
