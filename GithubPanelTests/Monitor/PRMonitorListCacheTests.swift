import XCTest
import GRDB
@testable import GithubPanel

@MainActor
final class PRMonitorListCacheTests: XCTestCase {
    func testMyPRsAndForLaterShowFromTheLastRunBeforeTheFirstRefresh() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success, mergeMethods: RepositoryMergeMethods(allowed: [.squash], suggested: .squash)),
                    row(number: 2, status: .pending)]
        let defaults = FakeDefaults()
        let store = LocalStore.inMemory()
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 100))
        let first = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults,
                                dateProvider: dateProvider, store: store)
        await first.refreshNow()
        first.moveToForLater(api.rows[0])

        let restarted = makeMonitor(api: FakeGitHubAPI(), tokenStore: FakeTokenStore(token: "token"), defaults: defaults, store: store)

        XCTAssertEqual(restarted.prRows, api.rows)
        XCTAssertEqual(restarted.myPullRequests.active.map(\.number), [2])
        XCTAssertEqual(restarted.myPullRequests.forLater.map(\.number), [1])
        XCTAssertEqual(restarted.lastRefreshAt, Date(timeIntervalSince1970: 100))
    }

    func testRefreshReplacesTheSavedList() async {
        let defaults = FakeDefaults()
        let store = LocalStore.inMemory()
        let first = FakeGitHubAPI()
        first.rows = [row(number: 1, status: .success)]
        await makeMonitor(api: first, tokenStore: FakeTokenStore(token: "token"), defaults: defaults, store: store).refreshNow()

        let api = FakeGitHubAPI()
        api.rows = [row(number: 3, status: .success)]
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults, store: store)
        await monitor.refreshNow()

        XCTAssertEqual(monitor.prRows.map(\.number), [3])
        XCTAssertEqual(makeMonitor(defaults: defaults, store: store).prRows.map(\.number), [3])
    }

    func testFailedRefreshKeepsTheSavedList() async {
        let defaults = FakeDefaults()
        let store = LocalStore.inMemory()
        let first = FakeGitHubAPI()
        first.rows = [row(number: 1, status: .success)]
        await makeMonitor(api: first, tokenStore: FakeTokenStore(token: "token"), defaults: defaults, store: store).refreshNow()

        let api = FakeGitHubAPI()
        api.openHandler = { _ in throw TestError(message: "offline") }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults, store: store)
        await monitor.refreshNow()

        XCTAssertEqual(monitor.prRows.map(\.number), [1])
        XCTAssertEqual(monitor.lastError, "offline")
        XCTAssertEqual(makeMonitor(defaults: defaults, store: store).prRows.map(\.number), [1])
    }

    func testToReviewShowsFromTheLastRunWithoutHiddenRequests() async {
        let api = FakeGitHubAPI()
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1), reviewRequestRow(number: 2)],
                                            fromMyTeams: [reviewRequestRow(number: 3)])
        let defaults = FakeDefaults()
        let store = LocalStore.inMemory()
        let first = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults, store: store)
        await first.refreshNow()
        first.hideReviewRequest(reviewRequestRow(number: 2))

        let restarted = makeMonitor(tokenStore: FakeTokenStore(token: "token"), defaults: defaults, store: store)

        XCTAssertEqual(restarted.reviewRequests.fromMe.map(\.number), [1])
        XCTAssertEqual(restarted.reviewRequests.fromMyTeams.map(\.number), [3])
        XCTAssertNotNil(restarted.lastReviewRequestsRefreshAt)
    }

    func testRestoredListPostsNoNotificationsOnTheFirstRefresh() async {
        let defaults = FakeDefaults()
        let store = LocalStore.inMemory()
        let first = FakeGitHubAPI()
        first.rows = [row(number: 1, status: .pending)]
        await makeMonitor(api: first, tokenStore: FakeTokenStore(token: "token"), defaults: defaults, store: store).refreshNow()

        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        let poster = FakeNotificationPoster()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"),
                                  notificationPoster: poster, defaults: defaults, store: store)
        await monitor.refreshNow()

        XCTAssertTrue(poster.posts.isEmpty)
    }

    func testClearingTheTokenForgetsTheSavedLists() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 2)], fromMyTeams: [])
        let defaults = FakeDefaults()
        let store = LocalStore.inMemory()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults, store: store)
        await monitor.refreshNow()

        monitor.clearToken()

        let restarted = makeMonitor(defaults: defaults, store: store)
        XCTAssertTrue(restarted.prRows.isEmpty)
        XCTAssertEqual(restarted.reviewRequests, .empty)
        XCTAssertNil(restarted.lastRefreshAt)
    }

    func testMockDataNeverTouchesTheSavedLists() async {
        let defaults = FakeDefaults()
        let store = LocalStore.inMemory()
        let first = FakeGitHubAPI()
        first.rows = [row(number: 1, status: .success)]
        await makeMonitor(api: first, tokenStore: FakeTokenStore(token: "token"), defaults: defaults, store: store).refreshNow()

        let api = FakeGitHubAPI()
        api.rows = [row(number: 9, status: .success)]
        let mock = PRMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: FakeNotificationPoster(),
                             defaults: defaults, timerScheduler: FakeTimerScheduler(),
                             dateProvider: FakeDateProvider(now: Date(timeIntervalSince1970: 0)),
                             hookRunner: FakeHookRunner(), isUsingMockData: true, store: store)
        XCTAssertTrue(mock.prRows.isEmpty)
        await mock.refreshNow()

        XCTAssertEqual(makeMonitor(defaults: defaults, store: store).prRows.map(\.number), [1])
    }

    func testUnreadableSavedListIsIgnored() async throws {
        let store = LocalStore.inMemory()
        try await store.database.write { db in
            try db.execute(sql: "INSERT INTO pull_request_list (kind, rows, savedAt) VALUES ('open', ?, 0)",
                           arguments: [Data("[{\"id\": 1}]".utf8)])
        }

        XCTAssertTrue(makeMonitor(store: store).prRows.isEmpty)
    }

    func testWhenAListLastLoadedComesFromSyncState() async {
        let store = LocalStore.inMemory()
        store.savePullRequestList(CachedPullRequestList(savedAt: Date(timeIntervalSince1970: 100),
                                                        rows: [row(number: 1, status: .success)]), as: .open)
        await store.recordSync(for: PullRequestListKind.open.key, attemptedAt: Date(timeIntervalSince1970: 300),
                               fetchedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(makeMonitor(store: store).lastRefreshAt, Date(timeIntervalSince1970: 200))
    }

    func testHistoryPagesShowFromTheLastRunWhileTheyReload() async {
        let api = FakeGitHubAPI()
        api.historyPages[1] = PullRequestHistoryPage(rows: [historyRow(number: 1)], page: 1, perPage: 10, totalCount: 11)
        api.historyPages[2] = PullRequestHistoryPage(rows: [historyRow(number: 11)], page: 2, perPage: 10, totalCount: 11)
        let store = LocalStore.inMemory()
        let first = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"),
                                dateProvider: FakeDateProvider(now: Date(timeIntervalSince1970: 100)), store: store)
        await first.refreshCurrentHistoryPage()
        await first.loadNextHistoryPage()

        let gate = SuspendedHistoryRequests()
        let restartedAPI = FakeGitHubAPI()
        restartedAPI.historyHandler = { _, _, page, perPage in try await gate.next(page: page, perPage: perPage) }
        let restarted = makeMonitor(api: restartedAPI, tokenStore: FakeTokenStore(token: "token"), store: store)
        XCTAssertEqual(restarted.historyRows.map(\.number), [1])
        XCTAssertEqual(restarted.lastHistoryRefreshAt, Date(timeIntervalSince1970: 100))

        let next = Task { await restarted.loadNextHistoryPage() }
        await gate.waitForRequestCount(1)
        XCTAssertEqual(restarted.historyRows.map(\.number), [11], "The saved page shows while it reloads")
        XCTAssertEqual(restarted.historyRangeText, "11-11 of 11")
        XCTAssertTrue(restarted.isHistoryLoading)
        await gate.resumeNext(returning: PullRequestHistoryPage(rows: [historyRow(number: 12)], page: 2, perPage: 10,
                                                                totalCount: 12))
        await next.value
        XCTAssertEqual(restarted.historyRows.map(\.number), [12])
    }

    func testRemovesTheListsSavedToDefaultsWithoutImportingThem() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        let defaults = FakeDefaults()
        let store = LocalStore.inMemory()
        await makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), store: store).refreshNow()
        defaults.stringValues["GithubPanel.cache.myPullRequests"] = "{\"savedAt\": 0, \"rows\": []}"
        defaults.stringValues["GithubPanel.cache.reviewRequests"] = "{\"savedAt\": 0, \"rows\": {}}"

        let monitor = makeMonitor(defaults: defaults, store: store)

        XCTAssertEqual(monitor.prRows.map(\.number), [1])
        XCTAssertNil(defaults.stringValues["GithubPanel.cache.myPullRequests"])
        XCTAssertNil(defaults.stringValues["GithubPanel.cache.reviewRequests"])
    }
}
