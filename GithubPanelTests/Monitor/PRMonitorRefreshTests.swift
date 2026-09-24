import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorRefreshTests: XCTestCase {
    func testTokenIsReadOnceAcrossMonitorOperationsUntilCredentialChanges() async {
        let api = FakeGitHubAPI()
        let tokenStore = FakeTokenStore(token: "first")
        let monitor = makeMonitor(api: api, tokenStore: tokenStore)

        monitor.start()
        await monitor.refreshNow()
        await monitor.refreshCurrentHistoryPage()
        await monitor.requestMerge(for: row(number: 1, status: .pending, canEnableAutoMerge: true))
        monitor.start()
        await monitor.refreshNow()

        XCTAssertEqual(tokenStore.loadTokenCallCount, 1)
        XCTAssertEqual(api.fetchOpenPRTokens, ["first", "first", "first"])
        XCTAssertTrue(api.fetchCurrentUserTokens.isEmpty)
        XCTAssertEqual(api.enableCalls, ["node-1"])

        monitor.saveToken("second")
        await monitor.refreshNow()

        XCTAssertEqual(tokenStore.loadTokenCallCount, 1)
        XCTAssertEqual(api.fetchOpenPRTokens.last, "second")

        monitor.clearToken()
        tokenStore.token = "external-change"
        await monitor.refreshNow()

        XCTAssertEqual(tokenStore.loadTokenCallCount, 1)
        XCTAssertEqual(api.fetchOpenPRTokens.last, "second")
    }

    func testRefreshSuccessPreservesAPIOrderAndTimestamp() async {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let api = FakeGitHubAPI()
        api.user = GitHubUser(login: "fred")
        api.rows = [row(number: 7, status: .success), row(number: 3, status: .pending)]
        let monitor = makeMonitor(api: api,
                                  tokenStore: FakeTokenStore(token: "token"),
                                  dateProvider: FakeDateProvider(now: fixedDate))

        await monitor.refreshNow()

        XCTAssertFalse(monitor.isLoading)
        XCTAssertNil(monitor.lastError)
        XCTAssertEqual(monitor.lastRefreshAt, fixedDate)
        XCTAssertEqual(monitor.prRows.map(\.number), [7, 3])
        XCTAssertEqual(api.fetchOpenPRTokens.count, 1)
    }

    func testConcurrentOpenRefreshesShareOneRequest() async {
        let gate = SuspendedOpenRequests()
        let api = FakeGitHubAPI()
        api.openHandler = { _ in try await gate.next() }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        let first = Task { await monitor.refreshNow() }
        await gate.waitForRequestCount(1)
        let second = Task { await monitor.refreshNow() }
        await Task.yield()

        let requestCount = await gate.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(monitor.isLoading)

        await gate.resumeNext(returning: OpenPullRequests(login: "fred", rows: [row(number: 1, status: .success)]))
        await first.value
        await second.value

        XCTAssertFalse(monitor.isLoading)
        XCTAssertEqual(monitor.prRows.map(\.number), [1])
    }

    func testMutationDuringRefreshQueuesOneFreshRequestAndDiscardsStaleRows() async {
        let gate = SuspendedOpenRequests()
        let api = FakeGitHubAPI()
        api.openHandler = { _ in try await gate.next() }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let item = row(number: 1, status: .success, mergeQueue: true)
        let mutationGate = MutationCalls()
        api.enqueueHandler = { id in await mutationGate.record(id) }

        let refresh = Task { await monitor.refreshNow() }
        await gate.waitForRequestCount(1)
        let mutation = Task { await monitor.requestMerge(for: item) }
        await mutationGate.waitForCount(1)

        XCTAssertEqual(api.enqueueCalls, ["node-1"])
        await gate.resumeNext(returning: OpenPullRequests(login: "fred", rows: [item]))
        await gate.waitForRequestCount(2)
        XCTAssertTrue(monitor.prRows.isEmpty)
        XCTAssertTrue(monitor.isLoading)

        let freshRow = row(number: 1,
                           status: .success,
                           mergeQueue: true,
                           inMergeQueue: true,
                           mergeStateStatus: "QUEUED")
        await gate.resumeNext(returning: OpenPullRequests(login: "fred", rows: [freshRow]))
        await mutation.value
        await refresh.value

        XCTAssertFalse(monitor.isLoading)
        XCTAssertEqual(monitor.prRows, [freshRow])
        let requestCount = await gate.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testMultipleMutationsCoalesceIntoOneFollowUpRequest() async {
        let gate = SuspendedOpenRequests()
        let api = FakeGitHubAPI()
        api.openHandler = { _ in try await gate.next() }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let firstRow = row(number: 1, status: .pending, canEnableAutoMerge: true)
        let secondRow = row(number: 2, status: .pending, canEnableAutoMerge: true)
        let mutationGate = MutationCalls()
        api.enableHandler = { id in await mutationGate.record(id) }

        let refresh = Task { await monitor.refreshNow() }
        await gate.waitForRequestCount(1)
        let firstMutation = Task { await monitor.requestMerge(for: firstRow) }
        let secondMutation = Task { await monitor.requestMerge(for: secondRow) }
        await mutationGate.waitForCount(2)

        XCTAssertEqual(api.enableCalls.sorted(), ["node-1", "node-2"])
        await gate.resumeNext(returning: OpenPullRequests(login: "fred", rows: [firstRow, secondRow]))
        await gate.waitForRequestCount(2)
        await gate.resumeNext(returning: OpenPullRequests(login: "fred",
                                                         rows: [row(number: 1, status: .pending, autoMerge: true),
                                                                row(number: 2, status: .pending, autoMerge: true)]))
        await firstMutation.value
        await secondMutation.value
        await refresh.value

        let requestCount = await gate.requestCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertFalse(monitor.isLoading)
    }

    func testFailedOpenRefreshReleasesTaskForRetry() async {
        let api = FakeGitHubAPI()
        api.error = TestError(message: "offline")
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshNow()

        XCTAssertFalse(monitor.isLoading)
        XCTAssertEqual(monitor.lastError, "offline")

        api.error = nil
        api.rows = [row(number: 1, status: .success)]
        await monitor.refreshNow()

        XCTAssertFalse(monitor.isLoading)
        XCTAssertNil(monitor.lastError)
        XCTAssertEqual(api.fetchOpenPRTokens.count, 2)
    }

    func testCredentialChangeDetachesOldRefreshWithoutClearingNewLoadingState() async {
        let gate = SuspendedOpenRequests()
        let api = FakeGitHubAPI()
        api.openHandler = { _ in try await gate.next() }
        let store = FakeTokenStore(token: "old")
        let monitor = makeMonitor(api: api, tokenStore: store)

        let oldRefresh = Task { await monitor.refreshNow() }
        await gate.waitForRequestCount(1)
        monitor.clearToken()
        monitor.saveToken("new")
        let newRefresh = Task { await monitor.refreshNow() }
        await gate.waitForRequestCount(2)

        await gate.resumeNext(returning: OpenPullRequests(login: "old-user", rows: [row(number: 1, status: .success)]))
        await oldRefresh.value
        XCTAssertTrue(monitor.isLoading)
        XCTAssertTrue(monitor.prRows.isEmpty)

        await gate.resumeNext(returning: OpenPullRequests(login: "new-user", rows: [row(number: 2, status: .success)]))
        await newRefresh.value

        XCTAssertFalse(monitor.isLoading)
        XCTAssertEqual(monitor.prRows.map(\.number), [2])
    }

    func testIdenticalRowsDoNotPublishAgainButRefreshTimestampAdvances() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 1000))
        let monitor = makeMonitor(api: api,
                                  tokenStore: FakeTokenStore(token: "token"),
                                  dateProvider: dateProvider)
        let publications = PublicationCounter()
        let cancellable = monitor.$prRows.dropFirst().sink { _ in publications.count += 1 }

        await monitor.refreshNow()
        let firstTimestamp = monitor.lastRefreshAt
        dateProvider.now = Date(timeIntervalSince1970: 2000)
        await monitor.refreshNow()

        _ = cancellable
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(firstTimestamp, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(monitor.lastRefreshAt, Date(timeIntervalSince1970: 2000))
    }

    func testChangedRowsOrOrderingPublishesOncePerChange() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .pending), row(number: 2, status: .success)]
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let publications = PublicationCounter()
        let cancellable = monitor.$prRows.dropFirst().sink { _ in publications.count += 1 }

        await monitor.refreshNow()
        api.rows[0] = row(number: 1, status: .success)
        await monitor.refreshNow()
        api.rows.reverse()
        await monitor.refreshNow()

        _ = cancellable
        XCTAssertEqual(publications.count, 3)
    }

    func testRefreshErrorClearsRowsAndStoresError() async {
        let api = FakeGitHubAPI()
        api.error = TestError(message: "boom")
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        monitor.prRows = [row(number: 1, status: .success)]

        await monitor.refreshNow()

        XCTAssertFalse(monitor.isLoading)
        XCTAssertTrue(monitor.prRows.isEmpty)
        XCTAssertEqual(monitor.lastError, "boom")
    }

    func testRefreshWithoutTokenDoesNothing() async {
        let api = FakeGitHubAPI()
        let tokenStore = FakeTokenStore(token: nil)
        let monitor = makeMonitor(api: api, tokenStore: tokenStore)

        await monitor.refreshNow()
        monitor.start()
        await monitor.refreshCurrentHistoryPage()

        XCTAssertFalse(monitor.isLoading)
        XCTAssertFalse(monitor.hasToken)
        XCTAssertTrue(api.fetchCurrentUserTokens.isEmpty)
        XCTAssertNil(monitor.lastRefreshAt)
        XCTAssertEqual(tokenStore.loadTokenCallCount, 1)
    }
}
