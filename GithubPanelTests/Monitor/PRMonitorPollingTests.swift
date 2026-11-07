import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorPollingTests: XCTestCase {
    func testTimerTickFetchesWhenNoRefreshHasRun() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshScheduler.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 1)
        XCTAssertEqual(api.fetchReviewRequestsTokens.count, 1)
        XCTAssertTrue(api.fetchClosedPRCalls.isEmpty)
    }

    func testTimerTickSkipsReviewRequestsWhileBackingOff() async {
        let api = FakeGitHubAPI()
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)

        await monitor.refreshNow()
        dateProvider.now = Date(timeIntervalSince1970: 29)
        await monitor.refreshScheduler.handleTimerTick()

        XCTAssertEqual(api.fetchReviewRequestsTokens.count, 1)
    }

    func testTimerTickSkipsFetchRightAfterRecentRefresh() async {
        let api = FakeGitHubAPI()
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)

        await monitor.refreshNow()
        dateProvider.now = Date(timeIntervalSince1970: 29)
        await monitor.refreshScheduler.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 1)

        dateProvider.now = Date(timeIntervalSince1970: 30)
        await monitor.refreshScheduler.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 2)
    }

    func testTimerTickUsesNormalCadenceAfterNonThrottlingFailure() async {
        let api = FakeGitHubAPI()
        api.error = TestError(message: "offline")
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)

        await monitor.refreshNow()
        dateProvider.now = Date(timeIntervalSince1970: 60)
        await monitor.refreshScheduler.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 2)
    }

    func testTimerTickBacksOffExponentiallyAfterAuthFailures() async {
        let api = FakeGitHubAPI()
        api.error = GraphQLError(message: "Bad credentials", statusCode: 401)
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)

        await monitor.refreshNow()
        for tick in [60, 120, 180, 240, 300, 360] {
            dateProvider.now = Date(timeIntervalSince1970: TimeInterval(tick))
            await monitor.refreshScheduler.handleTimerTick()
        }

        // Failure 1 at 0s waits two intervals (fetch at 120s); failure 2 waits four (fetch at 360s).
        // My PRs and To Review fail together, so each refresh counts as one failure.
        XCTAssertEqual(api.fetchOpenPRTokens.count, 3)
    }

    func testThrottledBackoffIsCappedAtThirtyMinutes() async {
        let api = FakeGitHubAPI()
        api.error = GitHubAPIError(message: "rate limited", documentationURL: nil, statusCode: 403)
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)

        // Each failure doubles the wait, less half an interval of slack for the timer: 90, 210, 450, 930 seconds.
        var failedAt: TimeInterval = 0
        await monitor.refreshNow()
        for wait in [90, 210, 450, 930] as [TimeInterval] {
            failedAt += wait
            dateProvider.now = Date(timeIntervalSince1970: failedAt)
            await monitor.refreshNow()
        }
        XCTAssertEqual(api.fetchOpenPRTokens.count, 5)

        dateProvider.now = Date(timeIntervalSince1970: failedAt + 1_769)
        await monitor.refreshScheduler.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 5)

        dateProvider.now = Date(timeIntervalSince1970: failedAt + 1_770)
        await monitor.refreshScheduler.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 6)
    }

    func testManualRefreshWhileBackingOffSendsNothingAndKeepsTheError() async {
        let api = FakeGitHubAPI()
        let throttled = GitHubAPIError(message: "rate limited", documentationURL: nil, statusCode: 403)
        api.error = throttled
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)
        await monitor.refreshNow()

        dateProvider.now = Date(timeIntervalSince1970: 10)
        await monitor.refreshNow()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 1)
        XCTAssertEqual(monitor.lastError, throttled.localizedDescription)
        XCTAssertFalse(monitor.isLoading)
    }

    func testThrottledPreloadBacksOffTheListsToo() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        api.detailHandler = { _ in throw GitHubAPIError(message: "rate limited", documentationURL: nil, statusCode: 403) }
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)
        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        dateProvider.now = Date(timeIntervalSince1970: 60)
        await monitor.refreshScheduler.handleTimerTick()
        XCTAssertEqual(api.fetchOpenPRTokens.count, 1)

        dateProvider.now = Date(timeIntervalSince1970: 120)
        await monitor.refreshScheduler.handleTimerTick()
        XCTAssertEqual(api.fetchOpenPRTokens.count, 2)
    }

    func testSuccessfulRefreshResetsThrottledBackoff() async {
        let api = FakeGitHubAPI()
        api.error = GraphQLError(message: "Too many requests", statusCode: 429)
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)

        await monitor.refreshNow()
        dateProvider.now = Date(timeIntervalSince1970: 90)
        api.error = nil
        await monitor.refreshNow()
        api.error = GraphQLError(message: "Too many requests", statusCode: 429)
        dateProvider.now = Date(timeIntervalSince1970: 120)
        await monitor.refreshScheduler.handleTimerTick()
        // Counted as a first failure again, so it waits two intervals less half of one.
        dateProvider.now = Date(timeIntervalSince1970: 210)
        await monitor.refreshScheduler.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 4)
    }

    func testTheTimerRefreshesInTheBackgroundAtTheRefreshInterval() async {
        let scheduler = FakeTimerScheduler()
        var refreshes: [(SyncEngine.Priority, TimeInterval)] = []
        let refreshed = expectation(description: "Timer refreshed")
        var interval: TimeInterval = 60
        let refreshScheduler = ListRefreshScheduler(timerScheduler: scheduler, interval: { interval }) { priority, maxAge in
            refreshes.append((priority, maxAge))
            refreshed.fulfill()
        }

        refreshScheduler.schedule()
        interval = 300
        refreshScheduler.schedule()
        scheduler.timers.last?.fire()
        await fulfillment(of: [refreshed], timeout: 5)

        XCTAssertEqual(scheduler.intervals, [60, 300])
        XCTAssertEqual(scheduler.timers.map(\.isInvalidated), [true, false])
        XCTAssertEqual(refreshes.map(\.0), [.background])
        XCTAssertEqual(refreshes.map(\.1), [150], "A list counts as fresh for half an interval")
    }
}
