import XCTest
import GRDB
@testable import GithubPanel

@MainActor
final class PullRequestCacheTests: XCTestCase {
    // MARK: - One record per pull request

    func testListedDetailsStayCachedOutsideTheLRULimit() {
        let cache = PullRequestCache(capacity: 1)
        let listed = row(number: 1, status: .success)
        cache.store(OpenPullRequests(login: "fred", rows: [listed]), fetchedAt: Date(timeIntervalSince1970: 0))
        cache.store(detailContent(for: listed.reference))

        cache.store(detailContent(for: PullRequestReference(repoFullName: "acme/widgets", number: 2)))

        XCTAssertNotNil(cache.entry(for: listed.reference))
        XCTAssertEqual(cache.open, [listed])
        XCTAssertEqual(cache.detailCount, 2)
    }

    func testPreloadedDetailsOfBothListsSurviveBeyondCapacity() {
        let cache = PullRequestCache(capacity: 1)
        let mine = row(number: 1, status: .success)
        let review = reviewRequestRow(number: 2)
        cache.store(OpenPullRequests(login: "fred", rows: [mine]), fetchedAt: Date())
        cache.store(ReviewRequests(fromMe: [review], fromMyTeams: []), fetchedAt: Date())
        for reference in [mine.reference, review.reference] {
            cache.store(detailContent(for: reference))
            cache.store(.empty, for: reference)
        }
        cache.store(detailContent(for: reference(3)))
        cache.store(detailContent(for: reference(4)))

        XCTAssertNotNil(cache.entry(for: mine.reference)?.comments)
        XCTAssertNotNil(cache.entry(for: review.reference)?.comments)
        XCTAssertNil(cache.entry(for: reference(3)))
        XCTAssertNotNil(cache.entry(for: reference(4)))

        cache.removeLists()
        XCTAssertEqual(cache.detailCount, 1, "Former list members return to the bounded LRU")
    }

    func testAPullRequestLeavingTheListsKeepsItsDetailUntilItIsEvicted() {
        let cache = PullRequestCache(capacity: 1)
        let listed = row(number: 1, status: .success)
        cache.store(OpenPullRequests(login: "fred", rows: [listed]), fetchedAt: Date(timeIntervalSince1970: 0))
        cache.store(detailContent(for: listed.reference))

        cache.store(OpenPullRequests(login: "fred", rows: []), fetchedAt: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(cache.open, [])
        XCTAssertNotNil(cache.entry(for: listed.reference))

        cache.store(detailContent(for: PullRequestReference(repoFullName: "acme/widgets", number: 2)))

        XCTAssertNil(cache.records[listed.reference], "Nothing needs it anymore")
    }

    func testRemovingTheListsKeepsTheDetailsAndRemovingTheDetailsKeepsTheLists() {
        let cache = PullRequestCache()
        let listed = row(number: 1, status: .success)
        cache.store(OpenPullRequests(login: "fred", rows: [listed]), fetchedAt: Date(timeIntervalSince1970: 0))
        cache.store(detailContent(for: listed.reference))

        cache.removeDetails()

        XCTAssertEqual(cache.open, [listed])
        XCTAssertEqual(cache.detailCount, 0)

        cache.store(detailContent(for: listed.reference))
        cache.removeLists()

        XCTAssertNil(cache.open)
        XCTAssertNotNil(cache.entry(for: listed.reference))
    }

    // MARK: - Details

    func testStoresDetailAndKeepsCommentsAcrossDetailUpdates() {
        let cache = PullRequestCache()
        let comments = PullRequestComments(comments: [], threads: [])

        cache.store(content(number: 1, title: "First"))
        cache.store(comments, for: reference(1))
        cache.store(content(number: 1, title: "Second"))

        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "Second")
        XCTAssertEqual(cache.entry(for: reference(1))?.comments, comments)
        XCTAssertNil(cache.entry(for: reference(2)))
    }

    func testIgnoresCommentsWithoutDetail() {
        let cache = PullRequestCache()

        cache.store(.empty, for: reference(1))

        XCTAssertNil(cache.entry(for: reference(1)))
        XCTAssertEqual(cache.detailCount, 0)
    }

    func testNeedsRefreshWhenMissingIncompleteOrOlderThanTheList() {
        let cache = PullRequestCache()
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
        let cache = PullRequestCache()
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
        let cache = PullRequestCache(capacity: 2)
        cache.store(content(number: 1))
        cache.store(content(number: 2))
        _ = cache.entry(for: reference(1))

        cache.store(content(number: 3))

        XCTAssertNotNil(cache.entry(for: reference(1)))
        XCTAssertNil(cache.entry(for: reference(2)))
        XCTAssertNotNil(cache.entry(for: reference(3)))
        XCTAssertEqual(cache.detailCount, 2)
    }

    func testRemoveAllEmptiesTheCache() {
        let cache = PullRequestCache()
        cache.store(content(number: 1))

        cache.removeDetails()

        XCTAssertNil(cache.entry(for: reference(1)))
        XCTAssertEqual(cache.detailCount, 0)
    }

    func testKeepsAHundredEntriesByDefault() {
        XCTAssertEqual(PullRequestCache().capacity, 100)
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

        let saving = PullRequestCache(store: store)
        saving.store(PullRequestDetailContent(detail: detail, files: [file]))
        saving.store(comments, for: reference(1))
        saving.store(checks, for: reference(1), headSHA: detail.headSHA)
        saving.store(content(number: 2))
        await saving.saveNow()

        let restored = PullRequestCache(store: store)
        await restored.waitForRestore()

        XCTAssertEqual(restored.detailCount, 2)
        XCTAssertEqual(restored.entry(for: reference(1)), saving.entry(for: reference(1)))
        XCTAssertFalse(restored.needsRefresh(reference(1), updatedAt: Date(timeIntervalSince1970: 100)))
    }

    func testRestoreKeepsTheUseOrderAndCapacity() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestCache(store: store)
        saving.store(content(number: 1))
        saving.store(content(number: 2))
        saving.store(content(number: 3))
        await saving.saveNow()

        let restored = PullRequestCache(capacity: 2, store: store)
        await restored.waitForRestore()

        XCTAssertNil(restored.entry(for: reference(1)), "The least recently used entry does not fit")
        XCTAssertNotNil(restored.entry(for: reference(2)))
        XCTAssertNotNil(restored.entry(for: reference(3)))
    }

    func testEntriesStoredBeforeTheRestoreFinishesWin() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestCache(store: store)
        saving.store(content(number: 1, title: "Saved"))
        await saving.saveNow()

        let restored = PullRequestCache(store: store)
        restored.store(content(number: 1, title: "Fresh"))
        await restored.waitForRestore()

        XCTAssertEqual(restored.entry(for: reference(1))?.content.detail.title, "Fresh")
    }

    func testSavesOnItsOwnAfterChanges() async throws {
        let store = LocalStore.inMemory()
        let saving = PullRequestCache(store: store, saveDelay: 0.01)
        saving.store(content(number: 1))

        for _ in 0..<200 where await store.pullRequestDetails().isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let restored = PullRequestCache(store: store)
        await restored.waitForRestore()
        XCTAssertNotNil(restored.entry(for: reference(1)))
    }

    func testSavesUseOrderAndEvictions() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestCache(capacity: 2, store: store)
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
        let saving = PullRequestCache(capacity: 1, store: store)
        saving.store(content(number: 1))
        saving.store(content(number: 2))
        saving.store(content(number: 1))
        await saving.saveNow()

        let saved = await store.pullRequestDetails().map(\.entry.content.detail.reference.number)
        XCTAssertEqual(saved, [1])
    }

    func testRemoveAllDeletesTheSavedEntries() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestCache(store: store)
        saving.store(content(number: 1))
        await saving.saveNow()

        saving.removeDetails()
        saving.store(content(number: 2))
        await saving.saveNow()

        let saved = await store.pullRequestDetails().map(\.entry.content.detail.reference.number)
        XCTAssertEqual(saved, [2])
    }

    func testIgnoresASavedEntryThatNoLongerDecodes() async throws {
        let store = LocalStore.inMemory()
        let saving = PullRequestCache(store: store)
        saving.store(content(number: 1))
        saving.store(content(number: 2))
        await saving.saveNow()
        try await store.database.write { db in
            try db.execute(sql: "UPDATE pull_request SET content = ? WHERE number = 1",
                           arguments: [Data("not json".utf8)])
        }

        let cache = PullRequestCache(store: store)
        await cache.waitForRestore()

        XCTAssertEqual(cache.detailCount, 1)
        XCTAssertNotNil(cache.entry(for: reference(2)))
    }

    // MARK: - Pending changes

    func testPendingChangesShowOnTopOfGitHubsCopy() {
        let cache = PullRequestCache()
        cache.store(content(number: 1, title: "Old"))
        var shown: [String] = []
        let subscription = cache.detailUpdates.sink { shown.append($0.1.content.detail.title) }

        cache.add(.title("New"), to: reference(1))
        cache.store(content(number: 1, title: "Reloaded"))
        subscription.cancel()

        XCTAssertEqual(shown, ["New", "New"], "A reload landing while the change waits doesn't show the old title")
        XCTAssertEqual(cache.shownEntry(for: reference(1))?.content.detail.title, "New")
        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "Reloaded")
    }

    func testAChangeReplacesAnEarlierOneToTheSameFieldUntilItStartsSending() {
        let cache = PullRequestCache()
        cache.store(content(number: 1))

        cache.add(.body("First"), to: reference(1))
        let second = cache.add(.body("Second"), to: reference(1))
        cache.add(.title("Title"), to: reference(1))
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.kind), [.body("Second"), .title("Title")])

        cache.markSending(second.id)
        cache.add(.body("Third"), to: reference(1))

        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.kind),
                       [.body("Second"), .title("Title"), .body("Third")])
        XCTAssertEqual(cache.nextChangeToSend(for: reference(1))?.kind, .title("Title"))
    }

    func testCommentsNeverReplaceEachOther() {
        let cache = PullRequestCache()
        cache.store(content(number: 1))

        cache.add(.comment(.general(body: "Same"), authorLogin: nil), to: reference(1))
        cache.add(.comment(.general(body: "Same"), authorLogin: nil), to: reference(1))

        XCTAssertEqual(cache.pendingChanges(for: reference(1)).count, 2)
    }

    func testPendingChangesAreSavedAndRestoredAndOnesThatWereSendingSendAgain() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestCache(store: store)
        saving.store(content(number: 1, title: "Old"))
        let sending = saving.add(.title("New"), to: reference(1))
        saving.markSending(sending.id)
        let failed = saving.add(.body("Body"), to: reference(1))
        saving.markFailed(failed.id, error: "Nope")
        await saving.saveNow()

        let restored = PullRequestCache(store: store)
        await restored.waitForRestore()

        let changes = restored.pendingChanges(for: reference(1))
        XCTAssertEqual(changes.map(\.id), [sending.id, failed.id])
        XCTAssertEqual(changes.map(\.state), [.pending, .failed])
        XCTAssertEqual(changes.map(\.error), [nil, "Nope"])
        XCTAssertEqual(restored.shownEntry(for: reference(1))?.content.detail.title, "New")
        XCTAssertEqual(restored.referencesWithChangesToSend, [reference(1)])
    }

    func testRemoveAllDropsPendingChanges() async {
        let store = LocalStore.inMemory()
        let saving = PullRequestCache(store: store)
        saving.store(content(number: 1))
        saving.add(.title("New"), to: reference(1))
        await saving.saveNow()

        saving.removeDetails()
        await saving.saveNow()

        XCTAssertTrue(saving.pendingChanges(for: reference(1)).isEmpty)
        let saved = await store.pendingChanges()
        XCTAssertTrue(saved.isEmpty)
    }

    private func reference(_ number: Int) -> PullRequestReference {
        PullRequestReference(repoFullName: "acme/widgets", number: number)
    }

    private func content(number: Int, title: String = "PR", updatedAt: Date? = nil) -> PullRequestDetailContent {
        detailContent(for: reference(number), title: title, updatedAt: updatedAt)
    }
}
