import XCTest
import GRDB
@testable import GithubPanel

/// The sync engine sending the changes waiting in the details cache.
@MainActor
final class PendingChangeSendingTests: XCTestCase {
    private let clock = TestClock()
    private var session = UUID()

    func testAPullRequestsChangesSendOneAtATimeInOrderWhileOthersSendAlongside() async throws {
        let api = loadingAPI()
        let gate = Gate()
        let firstSent = expectation(description: "First change sent")
        let otherSent = expectation(description: "Other pull request's change sent")
        var sent: [String] = []
        api.editHandler = { reference, title, body in
            sent.append("\(reference.number): \(title ?? body ?? "")")
            if reference.number == 2 { otherSent.fulfill() }
            if title == "First" {
                firstSent.fulfill()
                await gate.wait()
            }
        }
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.detail(reference(2)))

        cache.add(.title("First"), to: reference(1))
        cache.add(.body("Second"), to: reference(1))
        await engine.sendPendingChanges()
        await fulfillment(of: [firstSent], timeout: 5)
        cache.add(.title("Other"), to: reference(2))
        await engine.sendPendingChanges(for: reference(2))
        await fulfillment(of: [otherSent], timeout: 5)

        XCTAssertEqual(sent, ["1: First", "2: Other"], "The second change waits for the first")
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.state), [.sending, .pending])

        await gate.open()
        await engine.waitForPendingChanges()

        XCTAssertEqual(sent, ["1: First", "2: Other", "1: Second"])
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
    }

    func testGitHubsNewCopyIsSavedAndTheChangeDeletedInOneTransaction() async throws {
        let api = loadingAPI()
        var title = "Old"
        api.detailHandler = { reference in detailContent(for: reference, title: title) }
        api.editHandler = { _, newTitle, _ in title = newTitle ?? title }
        let store = LocalStore.inMemory()
        let cache = PullRequestDetailCache(store: store, saveDelay: 60)
        let engine = makeEngine(api: api, cache: cache, store: store)
        try await engine.request(.detail(reference(1)))
        await cache.saveNow()
        let commits = CommitObserver()
        store.database.add(transactionObserver: commits)
        var shown: [String] = []
        let subscription = cache.updates.sink { shown.append($0.1.content.detail.title) }

        cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        await cache.saveNow()
        subscription.cancel()

        XCTAssertFalse(shown.isEmpty)
        XCTAssertEqual(Set(shown), ["New"], "Never flickers back to the old title")
        XCTAssertTrue(commits.tables.contains { $0.contains("insert pull_request_detail") && $0.contains("delete pending_change") },
                      "Saved in one transaction: \(commits.tables)")
        let saved = await store.pullRequestDetails()
        XCTAssertEqual(saved.map(\.entry.content.detail.title), ["New"])
        let pending = await store.pendingChanges()
        XCTAssertTrue(pending.isEmpty)
    }

    func testAChangeWhoseReloadFailsStaysInTheCachedCopy() async throws {
        let api = loadingAPI()
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        api.detailHandler = { _ in throw GraphQLError(message: "Offline") }

        cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(api.editCalls.map(\.title), ["New"])
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "New")
    }

    func testAFailedChangeStaysUntilItIsRetriedOrDiscarded() async throws {
        let api = loadingAPI()
        var shouldFail = true
        var title = "Old"
        api.detailHandler = { reference in detailContent(for: reference, title: title) }
        api.editHandler = { _, newTitle, _ in
            if shouldFail { throw GraphQLError(message: "Nope") }
            title = newTitle ?? title
        }
        let store = LocalStore.inMemory()
        let cache = PullRequestDetailCache(store: store)
        let engine = makeEngine(api: api, cache: cache, store: store)
        try await engine.request(.detail(reference(1)))

        let change = cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.state), [.failed])
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.error), ["Nope"])
        XCTAssertEqual(cache.shownEntry(for: reference(1))?.content.detail.title, "New")
        await cache.saveNow()
        let saved = await store.pendingChanges()
        XCTAssertEqual(saved.map(\.state), [.failed], "Failed stays failed after a restart")

        // A failed change doesn't hold up later ones.
        cache.add(.fileViewed(pullRequestID: "node-1", path: "a.swift", viewed: true), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        XCTAssertEqual(api.setFileViewedCalls.count, 1)
        XCTAssertEqual(api.editCalls.count, 1, "A failed change waits for Retry")

        shouldFail = false
        cache.markPending(change.id)
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "New")

        shouldFail = true
        let discarded = cache.add(.title("Newer"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        cache.discard(discarded.id)

        XCTAssertEqual(cache.shownEntry(for: reference(1))?.content.detail.title, "New", "Back to GitHub's title")
        await cache.saveNow()
        let afterDiscard = await store.pendingChanges()
        XCTAssertTrue(afterDiscard.isEmpty)
    }

    func testChangesLeftByTheLastRunAreSentAgain() async throws {
        let api = loadingAPI()
        let store = LocalStore.inMemory()
        let lastRun = PullRequestDetailCache(store: store)
        await lastRun.waitForRestore()
        lastRun.add(.title("Waiting"), to: reference(1))
        let sending = lastRun.add(.threadResolved(threadID: "T", resolved: true), to: reference(2))
        lastRun.markSending(sending.id)
        let failed = lastRun.add(.body("Refused"), to: reference(1))
        lastRun.markFailed(failed.id, error: "Nope")
        await lastRun.saveNow()

        let cache = PullRequestDetailCache(store: store)
        let engine = makeEngine(api: api, cache: cache, store: store)
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(api.editCalls.map(\.title), ["Waiting"])
        XCTAssertEqual(api.setResolvedCalls.map(\.threadID), ["T"], "A change that was sending when the app quit is sent again")
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.id), [failed.id], "A failed change waits for the user")
        XCTAssertTrue(cache.pendingChanges(for: reference(2)).isEmpty)
    }

    func testANewTokenDropsTheOldAccountsChanges() async throws {
        let api = FakeGitHubAPI()
        api.detailHandler = { reference in detailContent(for: reference) }
        let gate = Gate()
        let sent = expectation(description: "First change sent")
        api.editHandler = { _, _, _ in
            sent.fulfill()
            await gate.wait()
        }
        let store = LocalStore.inMemory()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "old"), store: store)
        let cache = monitor.detailCache
        try await monitor.syncEngine.request(.detail(reference(1)))
        cache.add(.title("Sending"), to: reference(1))
        cache.add(.body("Waiting"), to: reference(1))
        await monitor.syncEngine.sendPendingChanges()
        await fulfillment(of: [sent], timeout: 5)

        monitor.saveToken("new")
        await gate.open()
        await monitor.syncEngine.sendPendingChanges()
        await monitor.syncEngine.waitForPendingChanges()
        await cache.saveNow()

        XCTAssertEqual(api.editCalls.map(\.token), ["old"], "Nothing the old account changed is sent with the new token")
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
        let saved = await store.pendingChanges()
        XCTAssertTrue(saved.isEmpty)
    }

    func testChangesWaitOutTheBackoffAsPending() async throws {
        let api = loadingAPI()
        api.checksHandler = { _ in throw GitHubAPIError(message: "Rate limited", documentationURL: nil, statusCode: 403) }
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        await XCTAssertThrowsAsync(try await engine.request(.checks(reference(1))))

        cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertTrue(api.editCalls.isEmpty)
        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.state), [.pending])

        clock.now += 90
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()

        XCTAssertEqual(api.editCalls.map(\.title), ["New"])
        XCTAssertTrue(cache.pendingChanges(for: reference(1)).isEmpty)
    }

    func testARefusedWriteFailsWithoutBackingOff() async throws {
        let api = loadingAPI()
        api.editHandler = { _, _, _ in throw GitHubAPIError(message: "Forbidden", documentationURL: nil, statusCode: 403) }
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))

        cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        try await engine.request(.checks(reference(1)))

        XCTAssertEqual(cache.pendingChanges(for: reference(1)).map(\.state), [.failed])
        XCTAssertEqual(api.checksCalls.count, 1, "GitHub refuses writes it doesn't allow with 403 too")
    }

    func testAResolvedThreadReloadsTheCommentsAndTitlesReloadMyPRs() async throws {
        let api = loadingAPI()
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache)
        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))

        cache.add(.threadResolved(threadID: "T", resolved: true), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        XCTAssertEqual(api.commentsCalls.count, 2)
        XCTAssertEqual(api.detailCalls.count, 1)
        XCTAssertTrue(api.fetchOpenPRTokens.isEmpty)

        cache.add(.title("New"), to: reference(1))
        await engine.sendPendingChanges()
        await engine.waitForPendingChanges()
        XCTAssertEqual(api.detailCalls.count, 2)
        XCTAssertEqual(api.fetchOpenPRTokens, ["token"])
    }

    // MARK: - Helpers

    private func makeEngine(api: FakeGitHubAPI, cache: PullRequestDetailCache,
                            store: LocalStore = .inMemory()) -> SyncEngine {
        SyncEngine(api: api, store: store, cache: cache, lists: PullRequestListCache(),
                   credential: { [unowned self] in SyncEngine.Credential(token: "token", session: session) },
                   now: { [clock] in clock.now })
    }

    private func loadingAPI() -> FakeGitHubAPI {
        let api = FakeGitHubAPI()
        api.detailHandler = { reference in detailContent(for: reference, title: "PR \(reference.number)") }
        return api
    }

    private func reference(_ number: Int) -> PullRequestReference {
        PullRequestReference(repoFullName: "acme/widgets", number: number)
    }
}

/// Records what each committed transaction changed, such as "insert pull_request_detail".
private final class CommitObserver: TransactionObserver {
    private(set) var tables: [Set<String>] = []
    private var current: Set<String> = []

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }

    func databaseDidChange(with event: DatabaseEvent) {
        let kind: String
        switch event.kind {
        case .insert: kind = "insert"
        case .update: kind = "update"
        case .delete: kind = "delete"
        }
        current.insert("\(kind) \(event.tableName)")
    }

    func databaseDidCommit(_ db: Database) {
        tables.append(current)
        current = []
    }

    func databaseDidRollback(_ db: Database) {
        current = []
    }
}
