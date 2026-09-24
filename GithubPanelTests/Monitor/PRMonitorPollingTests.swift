import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorPollingTests: XCTestCase {
    func testTimerTickFetchesWhenNoRefreshHasRun() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 1)
    }

    func testTimerTickSkipsFetchRightAfterRecentRefresh() async {
        let api = FakeGitHubAPI()
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)

        await monitor.refreshNow()
        dateProvider.now = Date(timeIntervalSince1970: 29)
        await monitor.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 1)

        dateProvider.now = Date(timeIntervalSince1970: 30)
        await monitor.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 2)
    }

    func testTimerTickUsesNormalCadenceAfterNonThrottlingFailure() async {
        let api = FakeGitHubAPI()
        api.error = TestError(message: "offline")
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)

        await monitor.refreshNow()
        dateProvider.now = Date(timeIntervalSince1970: 60)
        await monitor.handleTimerTick()

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
            await monitor.handleTimerTick()
        }

        // Failure 1 at 0s waits two intervals (fetch at 120s); failure 2 waits four (fetch at 360s).
        XCTAssertEqual(api.fetchOpenPRTokens.count, 3)
    }

    func testThrottledBackoffIsCappedAtThirtyMinutes() async {
        let api = FakeGitHubAPI()
        api.error = GitHubAPIError(message: "rate limited", documentationURL: nil, statusCode: 403)
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)

        for _ in 0..<10 {
            await monitor.refreshNow()
        }
        dateProvider.now = Date(timeIntervalSince1970: 1_769)
        await monitor.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 10)

        dateProvider.now = Date(timeIntervalSince1970: 1_770)
        await monitor.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 11)
    }

    func testSuccessfulRefreshResetsThrottledBackoff() async {
        let api = FakeGitHubAPI()
        api.error = GraphQLError(message: "Too many requests", statusCode: 429)
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)

        await monitor.refreshNow()
        await monitor.refreshNow()
        api.error = nil
        await monitor.refreshNow()
        dateProvider.now = Date(timeIntervalSince1970: 30)
        await monitor.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 4)
    }
}
