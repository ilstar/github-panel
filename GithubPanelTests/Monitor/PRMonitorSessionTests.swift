import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorSessionTests: XCTestCase {
    func testOpenRefreshSeedsLoginForHistory() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await monitor.refreshCurrentHistoryPage()
        await monitor.refreshCurrentHistoryPage()
        XCTAssertTrue(api.fetchCurrentUserTokens.isEmpty)
        XCTAssertEqual(api.historyUsernames, ["fred", "fred"])
    }

    func testSavingTokenInvalidatesCachedLogin() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "old"))
        await monitor.refreshCurrentHistoryPage()
        // The automatic open refresh fails; history must resolve the new identity itself.
        api.openHandler = { _ in throw TestError(message: "offline") }
        api.user = GitHubUser(login: "new-user")
        monitor.saveToken("new")
        await monitor.refreshCurrentHistoryPage()
        XCTAssertEqual(api.fetchCurrentUserTokens, ["old", "new"])
        XCTAssertEqual(api.historyUsernames, ["fred", "new-user"])
    }

    func testClearingTokenInvalidatesPreviouslyCachedLogin() async {
        let api = FakeGitHubAPI()
        let store = FakeTokenStore(token: "token")
        let monitor = makeMonitor(api: api, tokenStore: store)
        await monitor.refreshNow()
        monitor.clearToken()
        api.openHandler = { _ in throw TestError(message: "offline") }
        api.user = GitHubUser(login: "renamed-user")
        monitor.saveToken("token")
        await monitor.refreshNow()
        await monitor.refreshCurrentHistoryPage()
        XCTAssertEqual(api.fetchCurrentUserTokens, ["token"])
        XCTAssertEqual(api.historyUsernames, ["renamed-user"])
    }

    func testFailedUserLookupIsNotCached() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        api.userHandler = { _ in throw TestError(message: "offline") }
        await monitor.refreshCurrentHistoryPage()
        XCTAssertEqual(monitor.lastHistoryError, "offline")
        api.userHandler = nil
        await monitor.refreshCurrentHistoryPage()
        XCTAssertNil(monitor.lastHistoryError)
        XCTAssertEqual(api.fetchCurrentUserTokens, ["token", "token"])
        XCTAssertEqual(api.historyUsernames, ["fred"])
    }

    func testLateOpenResponseCannotRestoreClearedSession() async {
        let api = FakeGitHubAPI()
        let store = FakeTokenStore(token: "old")
        let monitor = makeMonitor(api: api, tokenStore: store)
        let started = expectation(description: "Open request started")
        var continuation: CheckedContinuation<OpenPullRequests, Error>?
        api.openHandler = { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let pending = Task { await monitor.refreshNow() }
        await fulfillment(of: [started], timeout: 2)
        monitor.clearToken()
        continuation?.resume(returning: OpenPullRequests(login: "old-user", rows: [row(number: 1, status: .success)]))
        await pending.value
        XCTAssertTrue(monitor.prRows.isEmpty)
        XCTAssertNil(monitor.lastRefreshAt)
        XCTAssertFalse(monitor.isLoading)
        api.openHandler = nil
        api.user = GitHubUser(login: "new-user")
        monitor.saveToken("new")
        await monitor.refreshNow()
        await monitor.refreshCurrentHistoryPage()
        XCTAssertEqual(api.fetchOpenPRTokens, ["old", "new"])
        XCTAssertTrue(api.fetchCurrentUserTokens.isEmpty)
        XCTAssertEqual(api.historyUsernames, ["new-user"])
    }

    func testLateUserResponseCannotReplaceNewSessionLogin() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "old"))
        let started = expectation(description: "User request started")
        var continuation: CheckedContinuation<GitHubUser, Error>?
        api.userHandler = { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let pending = Task { await monitor.refreshCurrentHistoryPage() }
        await fulfillment(of: [started], timeout: 2)
        api.user = GitHubUser(login: "new-user")
        monitor.saveToken("new")
        await monitor.refreshNow()
        continuation?.resume(returning: GitHubUser(login: "old-user"))
        await pending.value
        XCTAssertTrue(api.historyUsernames.isEmpty)
        await monitor.refreshCurrentHistoryPage()
        XCTAssertEqual(api.historyUsernames, ["new-user"])
        XCTAssertEqual(api.fetchCurrentUserTokens, ["old"])
    }

    func testClearTokenResetsState() {
        let tokenStore = FakeTokenStore(token: "token")
        let monitor = makeMonitor(tokenStore: tokenStore)
        monitor.hasToken = true
        monitor.prRows = [row(number: 1, status: .pending)]
        monitor.historyRows = [historyRow(number: 1)]
        monitor.historyTotalCount = 1
        monitor.historyPage = 2

        monitor.clearToken()

        XCTAssertNil(tokenStore.token)
        XCTAssertFalse(monitor.hasToken)
        XCTAssertTrue(monitor.prRows.isEmpty)
        XCTAssertTrue(monitor.historyRows.isEmpty)
        XCTAssertEqual(monitor.historyTotalCount, 0)
        XCTAssertEqual(monitor.historyPage, 1)
    }
}
