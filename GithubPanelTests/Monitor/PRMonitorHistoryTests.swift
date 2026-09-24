import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorHistoryTests: XCTestCase {
    func testSuccessfulEmptyHistoryLoadsOnlyOnceWhenUsingIfNeeded() async {
        let gate = SuspendedHistoryRequests()
        let api = FakeGitHubAPI()
        api.historyHandler = { _, _, page, perPage in
            try await gate.next(page: page, perPage: perPage)
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let loaded = expectation(description: "History loaded")
        let cancellable = monitor.$lastHistoryRefreshAt.dropFirst().sink { _ in loaded.fulfill() }

        monitor.loadHistoryIfNeeded()
        await gate.waitForRequestCount(1)
        monitor.loadHistoryIfNeeded()
        let initialRequestCount = await gate.requestCount
        XCTAssertEqual(initialRequestCount, 1)

        await gate.resumeNext(returning: PullRequestHistoryPage(rows: [], page: 1, perPage: 10, totalCount: 0))
        await fulfillment(of: [loaded], timeout: 2)
        _ = cancellable
        await Task.yield()

        monitor.loadHistoryIfNeeded()
        await Task.yield()
        let finalRequestCount = await gate.requestCount
        XCTAssertEqual(finalRequestCount, 1)
        XCTAssertTrue(monitor.historyRows.isEmpty)
    }

    func testIdenticalHistoryRowsDoNotPublishAgainButRefreshTimestampAdvances() async {
        let api = FakeGitHubAPI()
        api.historyPages[1] = PullRequestHistoryPage(rows: [historyRow(number: 1)],
                                                     page: 1,
                                                     perPage: 10,
                                                     totalCount: 1)
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 1000))
        let monitor = makeMonitor(api: api,
                                  tokenStore: FakeTokenStore(token: "token"),
                                  dateProvider: dateProvider)
        let publications = PublicationCounter()
        let cancellable = monitor.$historyRows.dropFirst().sink { _ in publications.count += 1 }

        await monitor.refreshCurrentHistoryPage()
        dateProvider.now = Date(timeIntervalSince1970: 2000)
        await monitor.refreshCurrentHistoryPage()

        _ = cancellable
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(monitor.lastHistoryRefreshAt, Date(timeIntervalSince1970: 2000))
    }

    func testFailedHistoryLoadRetriesAndExplicitRefreshReloads() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        api.historyHandler = { _, _, _, _ in throw TestError(message: "history offline") }

        await monitor.refreshCurrentHistoryPage()

        XCTAssertFalse(monitor.isHistoryLoading)
        XCTAssertEqual(monitor.lastHistoryError, "history offline")

        api.historyHandler = nil
        api.historyPages[1] = PullRequestHistoryPage(rows: [historyRow(number: 1)],
                                                     page: 1,
                                                     perPage: 10,
                                                     totalCount: 1)
        await monitor.refreshCurrentHistoryPage()
        XCTAssertNil(monitor.lastHistoryError)
        XCTAssertEqual(api.fetchClosedPRCalls.count, 2)

        await monitor.refreshCurrentHistoryPage()
        XCTAssertEqual(api.fetchClosedPRCalls.count, 3)
    }

    func testCredentialChangeResetsSuccessfulHistoryLoadState() async {
        let api = FakeGitHubAPI()
        let store = FakeTokenStore(token: "old")
        let monitor = makeMonitor(api: api, tokenStore: store)

        await monitor.refreshCurrentHistoryPage()
        XCTAssertEqual(api.fetchClosedPRCalls.count, 1)

        let gate = SuspendedHistoryRequests()
        api.historyHandler = { _, _, page, perPage in
            try await gate.next(page: page, perPage: perPage)
        }
        monitor.saveToken("new")
        monitor.loadHistoryIfNeeded()
        await gate.waitForRequestCount(1)

        XCTAssertEqual(api.fetchClosedPRCalls.count, 2)
        await gate.resumeNext(returning: PullRequestHistoryPage(rows: [], page: 1, perPage: 10, totalCount: 0))
    }

    func testRefreshHistoryLoadsRequestedPageAndPaginationState() async {
        let fixedDate = Date(timeIntervalSince1970: 2000)
        let api = FakeGitHubAPI()
        api.user = GitHubUser(login: "fred")
        api.historyPages[1] = PullRequestHistoryPage(rows: (1...10).map { historyRow(number: $0) },
                                                     page: 1,
                                                     perPage: 10,
                                                     totalCount: 12)
        api.historyPages[2] = PullRequestHistoryPage(rows: (11...12).map { historyRow(number: $0) },
                                                     page: 2,
                                                     perPage: 10,
                                                     totalCount: 12)
        let monitor = makeMonitor(api: api,
                                  tokenStore: FakeTokenStore(token: "token"),
                                  dateProvider: FakeDateProvider(now: fixedDate))

        await monitor.refreshCurrentHistoryPage()

        XCTAssertFalse(monitor.isHistoryLoading)
        XCTAssertNil(monitor.lastHistoryError)
        XCTAssertEqual(monitor.lastHistoryRefreshAt, fixedDate)
        XCTAssertEqual(monitor.historyRows.map(\.number), Array(1...10))
        XCTAssertEqual(monitor.historyRangeText, "1-10 of 12")
        XCTAssertFalse(monitor.canLoadPreviousHistoryPage)
        XCTAssertTrue(monitor.canLoadNextHistoryPage)

        await monitor.loadNextHistoryPage()

        XCTAssertEqual(monitor.historyPage, 2)
        XCTAssertEqual(monitor.historyRows.map(\.number), [11, 12])
        XCTAssertEqual(monitor.historyRangeText, "11-12 of 12")
        XCTAssertTrue(monitor.canLoadPreviousHistoryPage)
        XCTAssertFalse(monitor.canLoadNextHistoryPage)
        XCTAssertEqual(api.fetchClosedPRCalls.map(\.page), [1, 2])
        XCTAssertEqual(api.fetchCurrentUserTokens, ["token"])
    }

    func testRefreshHistoryErrorStoresSeparateError() async {
        let api = FakeGitHubAPI()
        api.error = TestError(message: "history boom")
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        monitor.historyRows = [historyRow(number: 1)]

        await monitor.refreshCurrentHistoryPage()

        XCTAssertFalse(monitor.isHistoryLoading)
        XCTAssertTrue(monitor.historyRows.isEmpty)
        XCTAssertEqual(monitor.lastHistoryError, "history boom")
        XCTAssertNil(monitor.lastError)
    }
}
