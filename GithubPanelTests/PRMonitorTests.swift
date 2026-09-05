import XCTest
import AppKit
@testable import GithubPanel

@MainActor
final class PRMonitorTests: XCTestCase {
    func testEmptyPullRequestsBackgroundAssetIsAvailable() {
        XCTAssertNotNil(NSImage(named: EmptyPullRequestsBackground.imageName))
    }

    func testEmptyMockGitHubAPIHasNoPullRequests() async throws {
        let api = MockGitHubAPI(isEmpty: true)

        let result = try await api.fetchOpenPRs(token: "token")

        XCTAssertTrue(result.rows.isEmpty)
    }

    func testInitialRefreshIntervalUsesDefaultOrStoredValue() {
        let defaultMonitor = makeMonitor(defaults: FakeDefaults())
        XCTAssertEqual(defaultMonitor.refreshInterval, 60)

        let defaults = FakeDefaults()
        defaults.values["GithubPanel.refreshInterval"] = 300
        let storedMonitor = makeMonitor(defaults: defaults)
        XCTAssertEqual(storedMonitor.refreshInterval, 300)
    }

    func testSelectedTabDefaultsToOpenAndCanSwitchToHistory() {
        let monitor = makeMonitor()

        XCTAssertEqual(monitor.selectedTab, .open)

        monitor.selectedTab = .history

        XCTAssertEqual(monitor.selectedTab, .history)
    }

    func testChangingRefreshIntervalPersistsAndReschedulesTimer() {
        let defaults = FakeDefaults()
        let scheduler = FakeTimerScheduler()
        let monitor = makeMonitor(defaults: defaults, timerScheduler: scheduler)

        monitor.refreshInterval = 600

        XCTAssertEqual(defaults.values["GithubPanel.refreshInterval"], 600)
        XCTAssertEqual(scheduler.intervals, [600])
    }

    func testHookScriptsLoadFromDefaultsAndPersistChanges() {
        let defaults = FakeDefaults()
        defaults.stringValues["GithubPanel.hooks.allSucceededScript"] = "say passed"
        defaults.stringValues["GithubPanel.hooks.anyFailuresScript"] = "say failed"
        let monitor = makeMonitor(defaults: defaults)

        XCTAssertEqual(monitor.allSucceededHookScript, "say passed")
        XCTAssertEqual(monitor.anyFailuresHookScript, "say failed")

        monitor.allSucceededHookScript = "echo ok"
        monitor.anyFailuresHookScript = "echo nope"

        XCTAssertEqual(defaults.stringValues["GithubPanel.hooks.allSucceededScript"], "echo ok")
        XCTAssertEqual(defaults.stringValues["GithubPanel.hooks.anyFailuresScript"], "echo nope")
    }

    func testStartUpdatesTokenPresenceAndSchedulesTimer() {
        let tokenStore = FakeTokenStore(token: "token")
        let scheduler = FakeTimerScheduler()
        let monitor = makeMonitor(tokenStore: tokenStore, timerScheduler: scheduler)

        monitor.start()

        XCTAssertTrue(monitor.hasToken)
        XCTAssertEqual(scheduler.intervals, [60])
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
        store.token = "token"
        api.user = GitHubUser(login: "renamed-user")
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
        store.token = "new"
        api.user = GitHubUser(login: "new-user")
        await monitor.refreshCurrentHistoryPage()
        XCTAssertEqual(api.fetchCurrentUserTokens, ["new"])
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
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))

        await monitor.refreshNow()

        XCTAssertFalse(monitor.isLoading)
        XCTAssertTrue(api.fetchCurrentUserTokens.isEmpty)
        XCTAssertNil(monitor.lastRefreshAt)
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

    func testNotificationPostsOnlyWhenPendingBecomesTerminalAndCleansStaleState() async {
        let api = FakeGitHubAPI()
        api.user = GitHubUser(login: "fred")
        api.rows = [row(number: 1, status: .unknown), row(number: 2, status: .unknown)]
        api.rows[0] = row(number: 1, status: .pending)
        api.rows[1] = row(number: 2, status: .success)
        let notifications = FakeNotificationPoster()
        let monitor = makeMonitor(api: api,
                                  tokenStore: FakeTokenStore(token: "token"),
                                  notificationPoster: notifications)

        await monitor.refreshNow()
        XCTAssertTrue(notifications.posts.isEmpty)

        api.rows = [row(number: 1, status: .unknown)]
        api.rows[0] = row(number: 1, status: .failure)
        await monitor.refreshNow()

        XCTAssertEqual(notifications.posts.count, 1)
        XCTAssertEqual(notifications.posts[0].state, .failure)
        XCTAssertEqual(notifications.posts[0].number, 1)

        api.rows = [row(number: 2, status: .unknown)]
        api.rows[0] = row(number: 2, status: .success)
        await monitor.refreshNow()

        XCTAssertEqual(notifications.posts.count, 1)
    }

    func testHooksRunWhenPendingBecomesSuccessfulOrFailed() async throws {
        let api = FakeGitHubAPI()
        api.user = GitHubUser(login: "fred")
        api.rows = [row(number: 1, status: .unknown), row(number: 2, status: .unknown)]
        api.rows[0] = row(number: 1, status: .pending)
        api.rows[1] = row(number: 2, status: .pending)
        let defaults = FakeDefaults()
        defaults.stringValues["GithubPanel.hooks.allSucceededScript"] = "echo success"
        defaults.stringValues["GithubPanel.hooks.anyFailuresScript"] = "echo failure"
        let hooks = FakeHookRunner()
        let monitor = makeMonitor(api: api,
                                  tokenStore: FakeTokenStore(token: "token"),
                                  defaults: defaults,
                                  hookRunner: hooks)

        await monitor.refreshNow()
        XCTAssertTrue(hooks.runs.isEmpty)

        api.rows[0] = row(number: 1, status: .success)
        api.rows[1] = row(number: 2, status: .failure)
        await monitor.refreshNow()

        XCTAssertEqual(hooks.runs.map(\.script).sorted(), ["echo failure", "echo success"])
        XCTAssertEqual(Set(hooks.runs.map(\.context.scenario)), [.allSucceeded, .anyFailures])
        let successRun = try XCTUnwrap(hooks.runs.first { $0.context.scenario == .allSucceeded })
        XCTAssertEqual(successRun.context.number, 1)
        XCTAssertEqual(successRun.context.environment["GITHUB_PANEL_PR_NUMBER"], "1")
        XCTAssertEqual(successRun.context.environment["GITHUB_PANEL_REPO_OWNER"], "acme")
        XCTAssertEqual(successRun.context.environment["GITHUB_PANEL_REPO_NAME"], "widgets")
        XCTAssertEqual(successRun.context.environment["GITHUB_PANEL_PR_HEAD_SHA"], "sha-1")
    }

    func testHooksIgnoreUnknownAndAlreadyTerminalStates() async {
        let api = FakeGitHubAPI()
        api.user = GitHubUser(login: "fred")
        api.rows = [row(number: 1, status: .unknown), row(number: 2, status: .unknown)]
        api.rows[0] = row(number: 1, status: .success)
        api.rows[1] = row(number: 2, status: .pending)
        let defaults = FakeDefaults()
        defaults.stringValues["GithubPanel.hooks.allSucceededScript"] = "echo success"
        defaults.stringValues["GithubPanel.hooks.anyFailuresScript"] = "echo failure"
        let hooks = FakeHookRunner()
        let monitor = makeMonitor(api: api,
                                  tokenStore: FakeTokenStore(token: "token"),
                                  defaults: defaults,
                                  hookRunner: hooks)

        await monitor.refreshNow()

        api.rows[0] = row(number: 1, status: .failure)
        api.rows[1] = row(number: 2, status: .unknown)
        await monitor.refreshNow()

        XCTAssertTrue(hooks.runs.isEmpty)
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

    func testDirectSuccessfulMergeRemovesRow() async {
        let api = FakeGitHubAPI()
        api.mergeResult = true
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let item = row(number: 1, status: .success)
        monitor.prRows = [item]

        await monitor.requestMerge(for: item)

        XCTAssertEqual(api.mergePullRequestCalls.count, 1)
        XCTAssertTrue(monitor.prRows.isEmpty)
    }

    func testDirectMergeFalseKeepsRow() async {
        let api = FakeGitHubAPI()
        api.mergeResult = false
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let item = row(number: 1, status: .success)
        monitor.prRows = [item]

        await monitor.requestMerge(for: item)

        XCTAssertEqual(api.mergePullRequestCalls.count, 1)
        XCTAssertEqual(monitor.prRows.count, 1)
    }

    func testMergeQueueEnqueuesAndRefreshes() async {
        let api = FakeGitHubAPI()
        api.user = GitHubUser(login: "fred")
        api.rows = [row(number: 1, status: .unknown)]
        api.rows[0] = row(number: 1, status: .success, inMergeQueue: true)
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let item = row(number: 1, status: .success, mergeQueue: true)

        await monitor.requestMerge(for: item)

        XCTAssertEqual(api.enqueueCalls, ["node-1"])
        XCTAssertEqual(monitor.prRows.first?.isInMergeQueue, true)
    }

    func testBlockedSuccessfulRowEnablesAutoMergeInsteadOfDirectMerge() async {
        let api = FakeGitHubAPI()
        api.user = GitHubUser(login: "fred")
        api.rows = [row(number: 1, status: .unknown)]
        api.rows[0] = row(number: 1,
                                                  status: .success,
                                                  autoMerge: true,
                                                  canDisableAutoMerge: true,
                                                  mergeStateStatus: "BLOCKED")
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let item = row(number: 1,
                       status: .success,
                       canEnableAutoMerge: true,
                       mergeStateStatus: "BLOCKED")

        await monitor.requestMerge(for: item)

        XCTAssertTrue(api.mergePullRequestCalls.isEmpty)
        XCTAssertEqual(api.enableCalls, ["node-1"])
        XCTAssertEqual(monitor.prRows.first?.isAutoMergeEnabled, true)
    }

    func testEnableAutoMergeAndDisableAutoMergeRefresh() async {
        let enableAPI = FakeGitHubAPI()
        enableAPI.user = GitHubUser(login: "fred")
        enableAPI.rows = [row(number: 1, status: .unknown)]
        enableAPI.rows[0] = row(number: 1, status: .pending, autoMerge: true)
        let enableMonitor = makeMonitor(api: enableAPI, tokenStore: FakeTokenStore(token: "token"))

        await enableMonitor.requestMerge(for: row(number: 1, status: .pending, canEnableAutoMerge: true))

        XCTAssertEqual(enableAPI.enableCalls, ["node-1"])
        XCTAssertEqual(enableMonitor.prRows.first?.isAutoMergeEnabled, true)

        let disableAPI = FakeGitHubAPI()
        disableAPI.user = GitHubUser(login: "fred")
        disableAPI.rows = [row(number: 1, status: .unknown)]
        disableAPI.rows[0] = row(number: 1, status: .pending, autoMerge: false)
        let disableMonitor = makeMonitor(api: disableAPI, tokenStore: FakeTokenStore(token: "token"))

        await disableMonitor.requestMerge(for: row(number: 1, status: .pending, autoMerge: true, canDisableAutoMerge: true))

        XCTAssertEqual(disableAPI.disableCalls, ["node-1"])
        XCTAssertEqual(disableMonitor.prRows.first?.isAutoMergeEnabled, false)
    }

    func testMergeNoOpsForBlockedRowsAndMissingPermissions() async {
        let cases = [
            row(number: 1, status: .failure),
            row(number: 2, status: .error),
            row(number: 3, status: .pending, inMergeQueue: true),
            row(number: 4, status: .pending, autoMerge: true, canDisableAutoMerge: false),
            row(number: 5, status: .pending, autoMerge: false, canEnableAutoMerge: false)
        ]

        for item in cases {
            let api = FakeGitHubAPI()
            let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
            await monitor.requestMerge(for: item)
            XCTAssertTrue(api.mergePullRequestCalls.isEmpty)
            XCTAssertTrue(api.enqueueCalls.isEmpty)
            XCTAssertTrue(api.enableCalls.isEmpty)
            XCTAssertTrue(api.disableCalls.isEmpty)
        }
    }

    func testMergeWithoutTokenDoesNothing() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))

        await monitor.requestMerge(for: row(number: 1, status: .success))

        XCTAssertTrue(api.mergePullRequestCalls.isEmpty)
    }
}

@MainActor
private func makeMonitor(api: FakeGitHubAPI = FakeGitHubAPI(),
                         tokenStore: FakeTokenStore = FakeTokenStore(token: nil),
                         notificationPoster: FakeNotificationPoster = FakeNotificationPoster(),
                         defaults: FakeDefaults = FakeDefaults(),
                         timerScheduler: FakeTimerScheduler = FakeTimerScheduler(),
                         dateProvider: FakeDateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0)),
                         hookRunner: FakeHookRunner = FakeHookRunner()) -> PRMonitor {
    PRMonitor(api: api,
              tokenStore: tokenStore,
              notificationPoster: notificationPoster,
              defaults: defaults,
              timerScheduler: timerScheduler,
              dateProvider: dateProvider,
              hookRunner: hookRunner)
}

private final class FakeGitHubAPI: GitHubAPIClient {
    var user = GitHubUser(login: "fred")
    var rows: [PullRequestRow] = []
    var historyPages: [Int: PullRequestHistoryPage] = [:]
    var error: Error?
    var mergeResult = true

    private(set) var fetchCurrentUserTokens: [String] = []
    var openHandler: ((String) async throws -> OpenPullRequests)?
    var userHandler: ((String) async throws -> GitHubUser)?
    private(set) var historyUsernames: [String] = []
    private(set) var fetchOpenPRTokens: [String] = []
    private(set) var fetchClosedPRCalls: [(page: Int, perPage: Int)] = []
    private(set) var enqueueCalls: [String] = []
    private(set) var enableCalls: [String] = []
    private(set) var disableCalls: [String] = []
    private(set) var mergePullRequestCalls: [(repoFullName: String, number: Int)] = []

    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        if let error { throw error }
        fetchCurrentUserTokens.append(token)
        if let userHandler { return try await userHandler(token) }
        return user
    }

    func fetchOpenPRs(token: String) async throws -> OpenPullRequests {
        fetchOpenPRTokens.append(token)
        if let openHandler { return try await openHandler(token) }
        if let error { throw error }
        return OpenPullRequests(login: user.login,
                                rows: rows)
    }

    func fetchClosedPRs(token: String, username: String, page: Int, perPage: Int) async throws -> PullRequestHistoryPage {
        if let error { throw error }
        historyUsernames.append(username)
        fetchClosedPRCalls.append((page, perPage))
        return historyPages[page] ?? PullRequestHistoryPage(rows: [],
                                                            page: page,
                                                            perPage: perPage,
                                                            totalCount: 0)
    }

    func enqueuePullRequest(token: String, pullRequestID: String) async throws {
        if let error { throw error }
        enqueueCalls.append(pullRequestID)
    }

    func enableAutoMerge(token: String, pullRequestID: String) async throws {
        if let error { throw error }
        enableCalls.append(pullRequestID)
    }

    func disableAutoMerge(token: String, pullRequestID: String) async throws {
        if let error { throw error }
        disableCalls.append(pullRequestID)
    }

    func mergePullRequest(token: String, repoFullName: String, number: Int) async throws -> Bool {
        if let error { throw error }
        mergePullRequestCalls.append((repoFullName, number))
        return mergeResult
    }
}

private final class FakeTokenStore: TokenStoring {
    var token: String?

    init(token: String?) {
        self.token = token
    }

    var hasToken: Bool {
        token != nil
    }

    func saveToken(_ token: String) {
        self.token = token
    }

    func loadToken() -> String? {
        token
    }

    func clearToken() {
        token = nil
    }
}

private final class FakeNotificationPoster: NotificationPosting {
    struct Post {
        let state: CheckState
        let title: String
        let repoFullName: String
        let number: Int
        let htmlURL: URL
    }

    private(set) var posts: [Post] = []

    func postStatusNotification(state: CheckState,
                                title: String,
                                repoFullName: String,
                                number: Int,
                                htmlURL: URL) {
        posts.append(Post(state: state,
                          title: title,
                          repoFullName: repoFullName,
                          number: number,
                          htmlURL: htmlURL))
    }
}

private final class FakeDefaults: DefaultsStoring {
    var values: [String: Double] = [:]
    var stringValues: [String: String] = [:]

    func double(forKey defaultName: String) -> Double {
        values[defaultName] ?? 0
    }

    func string(forKey defaultName: String) -> String? {
        stringValues[defaultName]
    }

    func set(_ value: Double, forKey defaultName: String) {
        values[defaultName] = value
    }

    func set(_ value: String, forKey defaultName: String) {
        stringValues[defaultName] = value
    }
}

private final class FakeHookRunner: PullRequestHookRunning {
    struct Run {
        let script: String
        let context: PullRequestHookContext
    }

    private(set) var runs: [Run] = []

    func run(script: String, context: PullRequestHookContext) {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        runs.append(Run(script: script, context: context))
    }
}

private struct FakeDateProvider: DateProviding {
    let now: Date
}

private final class FakeTimerScheduler: TimerScheduling {
    private(set) var intervals: [TimeInterval] = []
    private(set) var timers: [FakeTimer] = []

    func scheduledTimer(withTimeInterval interval: TimeInterval,
                        repeats: Bool,
                        block: @escaping @MainActor () -> Void) -> RefreshTimer {
        intervals.append(interval)
        let timer = FakeTimer()
        timers.append(timer)
        return timer
    }
}

private final class FakeTimer: RefreshTimer {
    private(set) var isInvalidated = false

    func invalidate() {
        isInvalidated = true
    }
}

private struct TestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func historyRow(number: Int,
                        mergedAt: Date? = Date(timeIntervalSince1970: 100)) -> PullRequestHistoryRow {
    PullRequestHistoryRow(id: "acme/widgets#\(number)",
                          title: "PR \(number)",
                          number: number,
                          repoFullName: "acme/widgets",
                          htmlURL: URL(string: "https://github.com/acme/widgets/pull/\(number)")!,
                          updatedAt: Date(timeIntervalSince1970: TimeInterval(number)),
                          closedAt: Date(timeIntervalSince1970: TimeInterval(number)),
                          mergedAt: mergedAt)
}

private func row(number: Int,
                 status: CheckState,
                 autoMerge: Bool = false,
                 canEnableAutoMerge: Bool = false,
                 canDisableAutoMerge: Bool = false,
                 mergeQueue: Bool = false,
                 inMergeQueue: Bool = false,
                 isDraft: Bool = false,
                 mergeStateStatus: String = "CLEAN") -> PullRequestRow {
    PullRequestRow(id: "acme/widgets#\(number)",
                   nodeID: "node-\(number)",
                   title: "PR \(number)",
                   number: number,
                   repoFullName: "acme/widgets",
                   htmlURL: URL(string: "https://github.com/acme/widgets/pull/\(number)")!,
                   headSHA: "sha-\(number)",
                   status: status,
                   isDraft: isDraft,
                   isAutoMergeEnabled: autoMerge,
                   canEnableAutoMerge: canEnableAutoMerge,
                   canDisableAutoMerge: canDisableAutoMerge,
                   isMergeQueueEnabled: mergeQueue,
                   isInMergeQueue: inMergeQueue,
                   mergeStateStatus: mergeStateStatus,
                   updatedAt: Date(timeIntervalSince1970: TimeInterval(number)))
}
