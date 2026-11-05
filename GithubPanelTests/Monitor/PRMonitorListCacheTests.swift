import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorListCacheTests: XCTestCase {
    func testMyPRsAndForLaterShowFromTheLastRunBeforeTheFirstRefresh() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success, mergeMethods: RepositoryMergeMethods(allowed: [.squash], suggested: .squash)),
                    row(number: 2, status: .pending)]
        let defaults = FakeDefaults()
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 100))
        let first = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults,
                                dateProvider: dateProvider)
        await first.refreshNow()
        first.moveToForLater(api.rows[0])

        let restarted = makeMonitor(api: FakeGitHubAPI(), tokenStore: FakeTokenStore(token: "token"), defaults: defaults)

        XCTAssertEqual(restarted.prRows, api.rows)
        XCTAssertEqual(restarted.myPullRequests.active.map(\.number), [2])
        XCTAssertEqual(restarted.myPullRequests.forLater.map(\.number), [1])
        XCTAssertEqual(restarted.lastRefreshAt, Date(timeIntervalSince1970: 100))
    }

    func testRefreshReplacesTheSavedList() async {
        let defaults = FakeDefaults()
        let first = FakeGitHubAPI()
        first.rows = [row(number: 1, status: .success)]
        await makeMonitor(api: first, tokenStore: FakeTokenStore(token: "token"), defaults: defaults).refreshNow()

        let api = FakeGitHubAPI()
        api.rows = [row(number: 3, status: .success)]
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults)
        await monitor.refreshNow()

        XCTAssertEqual(monitor.prRows.map(\.number), [3])
        XCTAssertEqual(makeMonitor(defaults: defaults).prRows.map(\.number), [3])
    }

    func testFailedRefreshKeepsTheSavedList() async {
        let defaults = FakeDefaults()
        let first = FakeGitHubAPI()
        first.rows = [row(number: 1, status: .success)]
        await makeMonitor(api: first, tokenStore: FakeTokenStore(token: "token"), defaults: defaults).refreshNow()

        let api = FakeGitHubAPI()
        api.openHandler = { _ in throw TestError(message: "offline") }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults)
        await monitor.refreshNow()

        XCTAssertEqual(monitor.prRows.map(\.number), [1])
        XCTAssertEqual(monitor.lastError, "offline")
        XCTAssertEqual(makeMonitor(defaults: defaults).prRows.map(\.number), [1])
    }

    func testToReviewShowsFromTheLastRunWithoutHiddenRequests() async {
        let api = FakeGitHubAPI()
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1), reviewRequestRow(number: 2)],
                                            fromMyTeams: [reviewRequestRow(number: 3)])
        let defaults = FakeDefaults()
        let first = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults)
        await first.refreshNow()
        first.hideReviewRequest(reviewRequestRow(number: 2))

        let restarted = makeMonitor(tokenStore: FakeTokenStore(token: "token"), defaults: defaults)

        XCTAssertEqual(restarted.reviewRequests.fromMe.map(\.number), [1])
        XCTAssertEqual(restarted.reviewRequests.fromMyTeams.map(\.number), [3])
        XCTAssertNotNil(restarted.lastReviewRequestsRefreshAt)
    }

    func testRestoredListPostsNoNotificationsOnTheFirstRefresh() async {
        let defaults = FakeDefaults()
        let first = FakeGitHubAPI()
        first.rows = [row(number: 1, status: .pending)]
        await makeMonitor(api: first, tokenStore: FakeTokenStore(token: "token"), defaults: defaults).refreshNow()

        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        let poster = FakeNotificationPoster()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"),
                                  notificationPoster: poster, defaults: defaults)
        await monitor.refreshNow()

        XCTAssertTrue(poster.posts.isEmpty)
    }

    func testClearingTheTokenForgetsTheSavedLists() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 2)], fromMyTeams: [])
        let defaults = FakeDefaults()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults)
        await monitor.refreshNow()

        monitor.clearToken()

        let restarted = makeMonitor(defaults: defaults)
        XCTAssertTrue(restarted.prRows.isEmpty)
        XCTAssertEqual(restarted.reviewRequests, .empty)
        XCTAssertNil(restarted.lastRefreshAt)
    }

    func testMockDataNeverTouchesTheSavedLists() async {
        let defaults = FakeDefaults()
        let first = FakeGitHubAPI()
        first.rows = [row(number: 1, status: .success)]
        await makeMonitor(api: first, tokenStore: FakeTokenStore(token: "token"), defaults: defaults).refreshNow()

        let api = FakeGitHubAPI()
        api.rows = [row(number: 9, status: .success)]
        let mock = PRMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: FakeNotificationPoster(),
                             defaults: defaults, timerScheduler: FakeTimerScheduler(),
                             dateProvider: FakeDateProvider(now: Date(timeIntervalSince1970: 0)),
                             hookRunner: FakeHookRunner(), isUsingMockData: true)
        XCTAssertTrue(mock.prRows.isEmpty)
        await mock.refreshNow()

        XCTAssertEqual(makeMonitor(defaults: defaults).prRows.map(\.number), [1])
    }

    func testUnreadableSavedListIsIgnored() {
        let defaults = FakeDefaults()
        defaults.stringValues["GithubPanel.cache.myPullRequests"] = "{\"savedAt\": 0, \"rows\": [{\"id\": 1}]}"

        XCTAssertTrue(makeMonitor(defaults: defaults).prRows.isEmpty)
    }
}
