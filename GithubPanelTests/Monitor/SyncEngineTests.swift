import XCTest
@testable import GithubPanel

@MainActor
final class SyncEngineTests: XCTestCase {
    private let clock = TestClock()
    private var session = UUID()
    private var token: String? = "token"

    func testRequestLoadsWithTheTokenIntoTheCacheAndRecordsIt() async throws {
        let api = loadingAPI()
        let cache = PullRequestDetailCache()
        let store = LocalStore.inMemory()
        let engine = makeEngine(api: api, cache: cache, store: store)
        clock.now = Date(timeIntervalSince1970: 100)

        try await engine.request(.detail(reference(1)))
        try await engine.request(.comments(reference(1), PullRequestCommentLimits()))
        try await engine.request(.checks(reference(1)))

        XCTAssertEqual(api.detailCalls.map(\.token), ["token"])
        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "PR 1")
        XCTAssertNotNil(cache.entry(for: reference(1))?.comments)
        XCTAssertNotNil(cache.entry(for: reference(1))?.checks)
        let state = await store.syncState(for: SyncEngine.Resource.detail(reference(1)).key)
        XCTAssertEqual(state, LocalStore.SyncState(fetchedAt: clock.now, lastAttemptAt: clock.now, lastError: nil))
    }

    func testRequestWithoutATokenFails() async {
        let api = loadingAPI()
        token = nil
        let engine = makeEngine(api: api)

        do {
            try await engine.request(.detail(reference(1)))
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is MissingTokenError)
        }
        XCTAssertTrue(api.detailCalls.isEmpty)
    }

    // MARK: - Dedupe

    func testARequestForAResourceAlreadyLoadingJoinsIt() async throws {
        let api = loadingAPI()
        let gate = Gate()
        let requested = expectation(description: "Detail requested")
        api.detailHandler = { reference in
            requested.fulfill()
            await gate.wait()
            return detailContent(for: reference, title: "Loaded")
        }
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache)

        let first = await engine.start(.detail(reference(1)))
        await fulfillment(of: [requested], timeout: 5)
        let second = await engine.start(.detail(reference(1)), maxAge: 60)
        await gate.open()
        try await first.value
        try await second.value

        XCTAssertEqual(api.detailCalls.count, 1)
        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "Loaded")
    }

    func testARefreshAfterAWriteLoadsAgainInsteadOfJoiningARequestAlreadySent() async throws {
        let api = loadingAPI()
        let gate = Gate()
        let requested = expectation(description: "First detail requested")
        var loads = 0
        api.detailHandler = { reference in
            loads += 1
            let title = "Load \(loads)"
            if loads == 1 {
                requested.fulfill()
                await gate.wait()
            }
            return detailContent(for: reference, title: title)
        }
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache)

        let first = await engine.start(.detail(reference(1)))
        await fulfillment(of: [requested], timeout: 5)
        let refresh = await engine.start(.detail(reference(1)), maxAge: 0)
        await gate.open()
        try await first.value
        try await refresh.value

        XCTAssertEqual(api.detailCalls.count, 2)
        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "Load 2", "The newer load is saved last")
    }

    func testCommentsAndChecksWaitForTheDetailLoadingAlongsideThem() async throws {
        let api = loadingAPI()
        let gate = Gate()
        api.detailHandler = { reference in
            await gate.wait()
            return detailContent(for: reference)
        }
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache)

        let detail = await engine.start(.detail(reference(1)))
        let comments = await engine.start(.comments(reference(1), PullRequestCommentLimits()))
        let checks = await engine.start(.checks(reference(1)))
        await gate.open()
        try await detail.value
        try await comments.value
        try await checks.value

        XCTAssertNotNil(cache.entry(for: reference(1))?.comments)
        XCTAssertNotNil(cache.entry(for: reference(1))?.checks)
    }

    // MARK: - Priority

    func testUserVisibleRequestsRunBeforeQueuedBackgroundOnes() async throws {
        let api = loadingAPI()
        let gate = Gate()
        let requested = expectation(description: "Background detail requested")
        api.detailHandler = { reference in
            if reference.number == 1 {
                requested.fulfill()
                await gate.wait()
            }
            return detailContent(for: reference)
        }
        let engine = makeEngine(api: api, maxBackgroundRequests: 1)

        let running = await engine.start(.detail(reference(1)), priority: .background)
        await fulfillment(of: [requested], timeout: 5)
        let queued = await engine.start(.detail(reference(2)), priority: .background)
        try await engine.request(.detail(reference(3)), priority: .userVisible)

        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1, 3], "The user's request didn't wait for a slot")
        await gate.open()
        try await running.value
        try await queued.value
        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1, 3, 2])
    }

    func testAUserVisibleRequestStartsTheQueuedBackgroundRequestItJoins() async throws {
        let api = loadingAPI()
        let gate = Gate()
        let requested = expectation(description: "Background detail requested")
        api.detailHandler = { reference in
            if reference.number == 1 {
                requested.fulfill()
                await gate.wait()
            }
            return detailContent(for: reference)
        }
        let engine = makeEngine(api: api, maxBackgroundRequests: 1)

        let running = await engine.start(.detail(reference(1)), priority: .background)
        await fulfillment(of: [requested], timeout: 5)
        let queued = await engine.start(.detail(reference(2)), priority: .background)
        try await engine.request(.detail(reference(2)), priority: .userVisible)

        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1, 2], "Joined, then started without waiting")
        await gate.open()
        try await running.value
        try await queued.value
        XCTAssertEqual(api.detailCalls.count, 2)
    }

    // MARK: - Freshness

    func testAResourceLoadedWithinMaxAgeIsNotLoadedAgain() async throws {
        let api = loadingAPI()
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache)

        try await engine.request(.detail(reference(1)))
        clock.now += 59
        try await engine.request(.detail(reference(1)), maxAge: 60)
        XCTAssertEqual(api.detailCalls.count, 1)

        try await engine.request(.detail(reference(1)), maxAge: 0)
        XCTAssertEqual(api.detailCalls.count, 2, "Zero always loads")

        clock.now += 61
        try await engine.request(.detail(reference(1)), maxAge: 60)
        XCTAssertEqual(api.detailCalls.count, 3)

        cache.removeAll()
        try await engine.request(.detail(reference(1)), maxAge: 60)
        XCTAssertEqual(api.detailCalls.count, 4, "Fresh only while the cache still holds it")
    }

    func testAFailedLoadRecordsTheErrorAndKeepsWhenItLastLoaded() async throws {
        let api = loadingAPI()
        let store = LocalStore.inMemory()
        let engine = makeEngine(api: api, store: store)
        let loadedAt = clock.now
        try await engine.request(.detail(reference(1)))

        api.detailHandler = { _ in throw TestError(message: "Offline") }
        clock.now += 10
        do {
            try await engine.request(.detail(reference(1)))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Offline")
        }

        let state = await store.syncState(for: SyncEngine.Resource.detail(reference(1)).key)
        XCTAssertEqual(state, LocalStore.SyncState(fetchedAt: loadedAt, lastAttemptAt: clock.now, lastError: "Offline"))
    }

    // MARK: - Backoff

    func testAThrottledLoadBacksOffEveryRequestUntilItEnds() async throws {
        let api = loadingAPI()
        let throttled = GitHubAPIError(message: "Rate limited", documentationURL: nil, statusCode: 403)
        api.detailHandler = { _ in throw throttled }
        let engine = makeEngine(api: api)

        await XCTAssertThrowsAsync(try await engine.request(.detail(reference(1))))
        do {
            try await engine.request(.checks(reference(2)))
            XCTFail("Expected the backoff to fail the request")
        } catch {
            XCTAssertEqual(error.localizedDescription, throttled.localizedDescription)
        }
        XCTAssertTrue(api.checksCalls.isEmpty)

        clock.now += 61
        try await engine.request(.checks(reference(2)))
        XCTAssertEqual(api.checksCalls.count, 1)
    }

    func testANewTokenEndsTheBackoff() async throws {
        let api = loadingAPI()
        api.detailHandler = { _ in throw GitHubAPIError(message: "Bad credentials", documentationURL: nil, statusCode: 401) }
        let engine = makeEngine(api: api)
        await XCTAssertThrowsAsync(try await engine.request(.detail(reference(1))))

        session = UUID()
        try await engine.request(.checks(reference(1)))

        XCTAssertEqual(api.checksCalls.count, 1)
    }

    func testOtherFailuresDoNotBackOff() async throws {
        let api = loadingAPI()
        api.detailHandler = { _ in throw GitHubAPIError(message: "Not Found", documentationURL: nil, statusCode: 404) }
        let engine = makeEngine(api: api)
        await XCTAssertThrowsAsync(try await engine.request(.detail(reference(1))))

        try await engine.request(.checks(reference(1)))

        XCTAssertEqual(api.checksCalls.count, 1)
    }

    // MARK: - Credential changes

    func testAResultLoadedWithAnOldTokenIsDropped() async throws {
        let api = loadingAPI()
        let gate = Gate()
        let requested = expectation(description: "Detail requested")
        var loads = 0
        api.detailHandler = { reference in
            loads += 1
            if loads == 1 {
                requested.fulfill()
                await gate.wait()
            }
            return detailContent(for: reference, title: "Load \(loads)")
        }
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache)
        let old = await engine.start(.detail(reference(1)), maxAge: 60)
        await fulfillment(of: [requested], timeout: 5)

        session = UUID()
        token = "new-token"
        cache.removeAll()
        let new = await engine.start(.detail(reference(1)), maxAge: 60)
        try await new.value
        await gate.open()

        do {
            try await old.value
            XCTFail("Expected the old load to be dropped")
        } catch {
            XCTAssertTrue(error is SyncEngine.CredentialChangedError)
        }
        XCTAssertEqual(api.detailCalls.map(\.token), ["token", "new-token"], "The new request didn't join the old one")
        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "Load 2")
    }

    func testResetCancelsQueuedRequests() async throws {
        let api = loadingAPI()
        let gate = Gate()
        let requested = expectation(description: "Background detail requested")
        api.detailHandler = { reference in
            requested.fulfill()
            await gate.wait()
            return detailContent(for: reference)
        }
        let cache = PullRequestDetailCache()
        let engine = makeEngine(api: api, cache: cache, maxBackgroundRequests: 1)
        let running = await engine.start(.detail(reference(1)), priority: .background)
        await fulfillment(of: [requested], timeout: 5)
        let queued = await engine.start(.checks(reference(2)), priority: .background)

        session = UUID()
        await engine.reset()
        await gate.open()

        await XCTAssertThrowsAsync(try await running.value)
        await XCTAssertThrowsAsync(try await queued.value)
        XCTAssertTrue(api.checksCalls.isEmpty)
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - Helpers

    private func makeEngine(api: FakeGitHubAPI, cache: PullRequestDetailCache? = nil,
                            store: LocalStore = .inMemory(), maxBackgroundRequests: Int = 3) -> SyncEngine {
        SyncEngine(api: api, store: store, cache: cache ?? PullRequestDetailCache(), credential: { [unowned self] in
            token.map { SyncEngine.Credential(token: $0, session: session) }
        }, now: { [clock] in clock.now }, maxBackgroundRequests: maxBackgroundRequests)
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

private func XCTAssertThrowsAsync(_ expression: @autoclosure () async throws -> Void,
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 0)
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
