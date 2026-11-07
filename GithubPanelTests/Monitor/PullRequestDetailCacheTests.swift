import XCTest
import GRDB
@testable import GithubPanel

@MainActor
final class PullRequestDetailCacheTests: XCTestCase {
    func testStoresDetailAndKeepsCommentsAcrossDetailUpdates() {
        let cache = PullRequestDetailCache()
        let comments = PullRequestComments(comments: [], threads: [])

        cache.store(content(number: 1, title: "First"))
        cache.store(comments, for: reference(1))
        cache.store(content(number: 1, title: "Second"))

        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "Second")
        XCTAssertEqual(cache.entry(for: reference(1))?.comments, comments)
        XCTAssertNil(cache.entry(for: reference(2)))
    }

    func testIgnoresCommentsWithoutDetail() {
        let cache = PullRequestDetailCache()

        cache.store(.empty, for: reference(1))

        XCTAssertNil(cache.entry(for: reference(1)))
        XCTAssertEqual(cache.count, 0)
    }

    func testNeedsRefreshWhenMissingIncompleteOrOlderThanTheList() {
        let cache = PullRequestDetailCache()
        let updatedAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(cache.needsRefresh(reference(1), updatedAt: updatedAt))

        cache.store(content(number: 1, updatedAt: updatedAt))
        XCTAssertTrue(cache.needsRefresh(reference(1), updatedAt: updatedAt), "Comments are not cached yet")

        cache.store(.empty, for: reference(1))
        XCTAssertTrue(cache.needsRefresh(reference(1), updatedAt: updatedAt), "Checks are not cached yet")
        cache.store(.empty, for: reference(1), headSHA: "sha-1")
        XCTAssertFalse(cache.needsRefresh(reference(1), updatedAt: updatedAt))
        XCTAssertFalse(cache.needsRefresh(reference(1), updatedAt: updatedAt.addingTimeInterval(-1)))
        XCTAssertTrue(cache.needsRefresh(reference(1), updatedAt: updatedAt.addingTimeInterval(1)))

        cache.store(content(number: 2, updatedAt: nil))
        cache.store(.empty, for: reference(2))
        XCTAssertTrue(cache.needsRefresh(reference(2), updatedAt: updatedAt), "No updatedAt to compare")
    }

    func testCommitChangesInvalidateChecksAndComparisonButKeepComments() {
        let cache = PullRequestDetailCache()
        var original = content(number: 1).detail
        original.lastReviewedSHA = "base"
        cache.store(PullRequestDetailContent(detail: original, files: []))
        cache.store(.empty, for: reference(1))
        cache.store(.empty, for: reference(1), headSHA: original.headSHA)
        cache.storeChanges([], for: reference(1), baseSHA: "base", headSHA: original.headSHA)
        XCTAssertNotNil(cache.entry(for: reference(1))?.filesSinceLastReview)

        var reviewed = original
        reviewed.lastReviewedSHA = "new-base"
        cache.store(PullRequestDetailContent(detail: reviewed, files: []))
        XCTAssertNotNil(cache.entry(for: reference(1))?.checks)
        XCTAssertNil(cache.entry(for: reference(1))?.filesSinceLastReview)

        let changed = PullRequestDetail(reference: original.reference, nodeID: original.nodeID,
            title: original.title, body: original.body, authorLogin: original.authorLogin, state: original.state,
            baseRef: original.baseRef, headRef: original.headRef, headSHA: "new-head", htmlURL: original.htmlURL,
            createdAt: original.createdAt, additions: 0, deletions: 0, changedFiles: 0, commits: 1)
        cache.store(PullRequestDetailContent(detail: changed, files: []))
        cache.store(.empty, for: reference(1), headSHA: original.headSHA)
        cache.storeChanges([], for: reference(1), baseSHA: "base", headSHA: original.headSHA)
        XCTAssertNil(cache.entry(for: reference(1))?.checks)
        XCTAssertNil(cache.entry(for: reference(1))?.filesSinceLastReview)
        XCTAssertNotNil(cache.entry(for: reference(1))?.comments)
    }

    func testEvictsTheLeastRecentlyUsedEntry() {
        let cache = PullRequestDetailCache(capacity: 2)
        cache.store(content(number: 1))
        cache.store(content(number: 2))
        _ = cache.entry(for: reference(1))

        cache.store(content(number: 3))

        XCTAssertNotNil(cache.entry(for: reference(1)))
        XCTAssertNil(cache.entry(for: reference(2)))
        XCTAssertNotNil(cache.entry(for: reference(3)))
        XCTAssertEqual(cache.count, 2)
    }

    func testRemoveAllEmptiesTheCache() {
        let cache = PullRequestDetailCache()
        cache.store(content(number: 1))

        cache.removeAll()

        XCTAssertNil(cache.entry(for: reference(1)))
        XCTAssertEqual(cache.count, 0)
    }

    func testKeepsAHundredEntriesByDefault() {
        XCTAssertEqual(PullRequestDetailCache().capacity, 100)
    }

    func testRestoresSavedEntriesFromTheStore() async {
        let store = LocalStore.inMemory()
        let comment = PullRequestComment(id: "c1", databaseID: 1, authorLogin: "octocat", body: "Looks good",
                                         createdAt: Date(timeIntervalSince1970: 10), htmlURL: nil)
        let thread = ReviewThread(id: "t1", path: "README.md", line: 3, startLine: nil, side: .right,
                                  isResolved: false, isOutdated: false, comments: [comment])
        let comments = PullRequestComments(comments: [comment], threads: [thread], totalCommentCount: 4)
        let checks = PullRequestChecks(checks: [
            PullRequestCheck(id: "k1", name: "Tests", workflowName: "CI", outcome: .failure, summary: nil,
                             startedAt: nil, completedAt: nil, detailsURL: nil, rerun: .workflowRun(9))
        ])
        let file = PullRequestFile(filename: "README.md", previousFilename: nil, status: .modified,
                                   additions: 1, deletions: 0, patch: "@@ -1 +1 @@\n+hi", isViewed: true)
        var detail = content(number: 1, updatedAt: Date(timeIntervalSince1970: 100)).detail
        detail.reviewers = PullRequestReviewers(decision: .approved, reviewers: [
            PullRequestReviewer(name: "hubot", kind: .user, state: .approved)
        ])

        let saving = PullRequestDetailCache(store: store)
        saving.store(PullRequestDetailContent(detail: detail, files: [file]))
        saving.store(comments, for: reference(1))
        saving.store(checks, for: reference(1), headSHA: detail.headSHA)
        saving.store(content(number: 2))
        await saving.saveNow()

        let restored = PullRequestDetailCache(store: store)
        await restored.waitForRestore()

        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.entry(for: reference(1)), saving.entry(for: reference(1)))
        XCTAssertFalse(restored.needsRefresh(reference(1), updatedAt: Date(timeIntervalSince1970: 100)))
    }

    func testRestoreKeepsTheUseOrderAndCapacity() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestDetailCache(store: store)
        saving.store(content(number: 1))
        saving.store(content(number: 2))
        saving.store(content(number: 3))
        await saving.saveNow()

        let restored = PullRequestDetailCache(capacity: 2, store: store)
        await restored.waitForRestore()

        XCTAssertNil(restored.entry(for: reference(1)), "The least recently used entry does not fit")
        XCTAssertNotNil(restored.entry(for: reference(2)))
        XCTAssertNotNil(restored.entry(for: reference(3)))
    }

    func testEntriesStoredBeforeTheRestoreFinishesWin() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestDetailCache(store: store)
        saving.store(content(number: 1, title: "Saved"))
        await saving.saveNow()

        let restored = PullRequestDetailCache(store: store)
        restored.store(content(number: 1, title: "Fresh"))
        await restored.waitForRestore()

        XCTAssertEqual(restored.entry(for: reference(1))?.content.detail.title, "Fresh")
    }

    func testSavesOnItsOwnAfterChanges() async throws {
        let store = LocalStore.inMemory()
        let saving = PullRequestDetailCache(store: store, saveDelay: 0.01)
        saving.store(content(number: 1))

        for _ in 0..<200 where await store.pullRequestDetails().isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let restored = PullRequestDetailCache(store: store)
        await restored.waitForRestore()
        XCTAssertNotNil(restored.entry(for: reference(1)))
    }

    func testSavesUseOrderAndEvictions() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestDetailCache(capacity: 2, store: store)
        saving.store(content(number: 1))
        saving.store(content(number: 2))
        await saving.saveNow()
        _ = saving.entry(for: reference(1))
        saving.store(content(number: 3))
        await saving.saveNow()

        let saved = await store.pullRequestDetails().map(\.entry.content.detail.reference.number)
        XCTAssertEqual(saved, [1, 3])
    }

    func testAnEvictedEntryStoredAgainIsSaved() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestDetailCache(capacity: 1, store: store)
        saving.store(content(number: 1))
        saving.store(content(number: 2))
        saving.store(content(number: 1))
        await saving.saveNow()

        let saved = await store.pullRequestDetails().map(\.entry.content.detail.reference.number)
        XCTAssertEqual(saved, [1])
    }

    func testRemoveAllDeletesTheSavedEntries() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestDetailCache(store: store)
        saving.store(content(number: 1))
        await saving.saveNow()

        saving.removeAll()
        saving.store(content(number: 2))
        await saving.saveNow()

        let saved = await store.pullRequestDetails().map(\.entry.content.detail.reference.number)
        XCTAssertEqual(saved, [2])
    }

    func testIgnoresASavedEntryThatNoLongerDecodes() async throws {
        let store = LocalStore.inMemory()
        let saving = PullRequestDetailCache(store: store)
        saving.store(content(number: 1))
        saving.store(content(number: 2))
        await saving.saveNow()
        try await store.database.write { db in
            try db.execute(sql: "UPDATE pull_request_detail SET content = ? WHERE number = 1",
                           arguments: [Data("not json".utf8)])
        }

        let cache = PullRequestDetailCache(store: store)
        await cache.waitForRestore()

        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.entry(for: reference(2)))
    }

    private func reference(_ number: Int) -> PullRequestReference {
        PullRequestReference(repoFullName: "acme/widgets", number: number)
    }

    private func content(number: Int, title: String = "PR", updatedAt: Date? = nil) -> PullRequestDetailContent {
        detailContent(for: reference(number), title: title, updatedAt: updatedAt)
    }
}
