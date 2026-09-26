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

    func testErrorClearsRowsAndStoresSeparateError() async {
        let api = FakeGitHubAPI()
        api.reviewRequestsHandler = { _ in throw TestError(message: "reviews offline") }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        monitor.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])

        await monitor.refreshReviewRequests()

        XCTAssertFalse(monitor.isReviewRequestsLoading)
        XCTAssertEqual(monitor.reviewRequests, .empty)
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

    func testClearingTokenClearsReviewRequests() async {
        let api = FakeGitHubAPI()
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshReviewRequests()

        monitor.clearToken()

        XCTAssertEqual(monitor.reviewRequests, .empty)
        XCTAssertFalse(monitor.isReviewRequestsLoading)
    }
}
