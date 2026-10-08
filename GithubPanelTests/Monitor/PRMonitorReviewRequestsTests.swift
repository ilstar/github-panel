import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorReviewRequestsTests: XCTestCase {
    func testRefreshLoadsReviewRequestsAndTimestamp() async {
        let api = FakeGitHubAPI()
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)],
                                            fromMyTeams: [reviewRequestRow(number: 2)])
        let fixedDate = Date(timeIntervalSince1970: 2000)
        let monitor = makeMonitor(api: api,
                                  tokenStore: FakeTokenStore(token: "token"),
                                  dateProvider: FakeDateProvider(now: fixedDate))

        await monitor.refreshReviewRequests()

        XCTAssertFalse(monitor.isReviewRequestsLoading)
        XCTAssertNil(monitor.lastReviewRequestsError)
        XCTAssertEqual(monitor.reviewRequests, api.reviewRequests)
        XCTAssertEqual(monitor.lastReviewRequestsRefreshAt, fixedDate)
        XCTAssertEqual(api.fetchReviewRequestsTokens, ["token"])
    }

    func testRefreshWithoutTokenDoesNothing() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))

        await monitor.refreshReviewRequests()

        XCTAssertTrue(api.fetchReviewRequestsTokens.isEmpty)
        XCTAssertNil(monitor.lastReviewRequestsRefreshAt)
    }

    func testErrorKeepsLastRowsAndStoresSeparateError() async {
        let api = FakeGitHubAPI()
        api.reviewRequestsHandler = { _ in throw TestError(message: "reviews offline") }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let requests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])
        monitor.reviewRequests = requests

        await monitor.refreshReviewRequests()

        XCTAssertFalse(monitor.isReviewRequestsLoading)
        XCTAssertEqual(monitor.reviewRequests, requests)
        XCTAssertEqual(monitor.lastReviewRequestsError, "reviews offline")
        XCTAssertNil(monitor.lastError)
        XCTAssertNil(monitor.lastHistoryError)
    }

    func testIdenticalReviewRequestsDoNotPublishAgain() async {
        let api = FakeGitHubAPI()
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let publications = PublicationCounter()
        let cancellable = monitor.$reviewRequests.dropFirst().sink { _ in publications.count += 1 }

        await monitor.refreshReviewRequests()
        await monitor.refreshReviewRequests()

        _ = cancellable
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(api.fetchReviewRequestsTokens.count, 2)
    }

    func testHiddenReviewRequestStaysHiddenAcrossRefreshes() async {
        let api = FakeGitHubAPI()
        var hidden = reviewRequestRow(number: 1)
        hidden.headSHA = "sha-1"
        api.reviewRequests = ReviewRequests(fromMe: [hidden], fromMyTeams: [reviewRequestRow(number: 2)])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshReviewRequests()

        monitor.hideReviewRequest(hidden)
        XCTAssertEqual(monitor.reviewRequests.rows.map(\.number), [2])

        await monitor.refreshReviewRequests()
        XCTAssertEqual(monitor.reviewRequests.rows.map(\.number), [2])
    }

    func testHiddenReviewRequestShowsAgainAfterNewCommits() async {
        let api = FakeGitHubAPI()
        var row = reviewRequestRow(number: 1)
        row.headSHA = "sha-1"
        api.reviewRequests = ReviewRequests(fromMe: [row], fromMyTeams: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshReviewRequests()
        monitor.hideReviewRequest(row)

        row.headSHA = "sha-2"
        api.reviewRequests = ReviewRequests(fromMe: [row], fromMyTeams: [])
        await monitor.refreshReviewRequests()

        XCTAssertEqual(monitor.reviewRequests.rows, [row])
    }

    func testHiddenReviewRequestShowsAgainWhenReviewIsRequestedAgain() async {
        let api = FakeGitHubAPI()
        var row = reviewRequestRow(number: 1)
        row.requestedAt = Date(timeIntervalSince1970: 100)
        api.reviewRequests = ReviewRequests(fromMe: [row], fromMyTeams: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshReviewRequests()
        monitor.hideReviewRequest(row)

        row.requestedAt = Date(timeIntervalSince1970: 200)
        api.reviewRequests = ReviewRequests(fromMe: [row], fromMyTeams: [])
        await monitor.refreshReviewRequests()

        XCTAssertEqual(monitor.reviewRequests.rows, [row])
    }

    func testHiddenReviewRequestIsForgottenOnceItLeavesTheList() async {
        let api = FakeGitHubAPI()
        let row = reviewRequestRow(number: 1)
        api.reviewRequests = ReviewRequests(fromMe: [row], fromMyTeams: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshReviewRequests()
        monitor.hideReviewRequest(row)

        api.reviewRequests = .empty
        await monitor.refreshReviewRequests()
        api.reviewRequests = ReviewRequests(fromMe: [row], fromMyTeams: [])
        await monitor.refreshReviewRequests()

        XCTAssertEqual(monitor.reviewRequests.rows, [row])
    }

    func testHiddenReviewRequestsAreRememberedAcrossLaunches() async {
        let api = FakeGitHubAPI()
        var row = reviewRequestRow(number: 1)
        row.headSHA = "sha-1"
        row.requestedAt = Date(timeIntervalSince1970: 100)
        api.reviewRequests = ReviewRequests(fromMe: [row, reviewRequestRow(number: 2)], fromMyTeams: [])
        let defaults = FakeDefaults()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults)
        await monitor.refreshReviewRequests()
        monitor.hideReviewRequest(row)

        let relaunched = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults)
        await relaunched.refreshReviewRequests()

        XCTAssertEqual(relaunched.reviewRequests.rows.map(\.number), [2])
    }

    func testClearingTokenClearsReviewRequests() async {
        let api = FakeGitHubAPI()
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshReviewRequests()

        monitor.clearToken()

        XCTAssertEqual(monitor.reviewRequests, .empty)
        XCTAssertFalse(monitor.isReviewRequestsLoading)
    }

    func testSwitchingBetweenMyPullRequestsAndReviewsDoesNotFetch() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        monitor.selectedTab = .reviews
        monitor.selectedTab = .open
        monitor.selectedTab = .reviews
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(api.fetchReviewRequestsTokens.isEmpty)
        XCTAssertTrue(api.fetchOpenPRTokens.isEmpty)
        XCTAssertTrue(api.fetchClosedPRCalls.isEmpty)
    }

    func testRefreshNowLoadsMyPullRequestsAndReviewRequestsTogether() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 2)], fromMyTeams: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshNow()

        XCTAssertEqual(monitor.prRows.map(\.number), [1])
        XCTAssertEqual(monitor.reviewRequests, api.reviewRequests)
        XCTAssertFalse(monitor.isLoading)
        XCTAssertFalse(monitor.isReviewRequestsLoading)
        XCTAssertTrue(api.fetchClosedPRCalls.isEmpty)
    }

    func testStartLoadsReviewRequests() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        monitor.start()

        await waitUntil { api.fetchReviewRequestsTokens.count == 1 && api.fetchOpenPRTokens.count == 1 }
        XCTAssertTrue(api.fetchClosedPRCalls.isEmpty)
    }

    func testReviewRequestFailureDoesNotClearMyPullRequests() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        api.reviewRequestsHandler = { _ in throw TestError(message: "reviews offline") }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshNow()

        XCTAssertEqual(monitor.prRows.map(\.number), [1])
        XCTAssertNil(monitor.lastError)
        XCTAssertEqual(monitor.lastReviewRequestsError, "reviews offline")
    }

    func testRefreshSelectedTabRefreshesBothListsFromEitherTab() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        monitor.selectedTab = .reviews
        await monitor.refreshSelectedTab()
        XCTAssertEqual(api.fetchReviewRequestsTokens.count, 1)
        XCTAssertEqual(api.fetchOpenPRTokens.count, 1)

        monitor.selectedTab = .open
        await monitor.refreshSelectedTab()
        XCTAssertEqual(api.fetchReviewRequestsTokens.count, 2)
        XCTAssertEqual(api.fetchOpenPRTokens.count, 2)
        XCTAssertTrue(api.fetchClosedPRCalls.isEmpty)
    }

    func testSelectedTabLoadingFollowsTheVisibleTab() {
        let monitor = makeMonitor()
        monitor.isReviewRequestsLoading = true

        XCTAssertFalse(monitor.isSelectedTabLoading)
        monitor.selectedTab = .reviews
        XCTAssertTrue(monitor.isSelectedTabLoading)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}
