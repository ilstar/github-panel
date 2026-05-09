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

        let summaries = try await api.fetchOpenPRs(token: "token", username: "mock-user")

        XCTAssertTrue(summaries.isEmpty)
    }

    func testInitialRefreshIntervalUsesDefaultOrStoredValue() {
        let defaultMonitor = makeMonitor(defaults: FakeDefaults())
        XCTAssertEqual(defaultMonitor.refreshInterval, 60)

        let defaults = FakeDefaults()
        defaults.values["GithubPanel.refreshInterval"] = 300
        let storedMonitor = makeMonitor(defaults: defaults)
        XCTAssertEqual(storedMonitor.refreshInterval, 300)
    }

    func testChangingRefreshIntervalPersistsAndReschedulesTimer() {
        let defaults = FakeDefaults()
        let scheduler = FakeTimerScheduler()
        let monitor = makeMonitor(defaults: defaults, timerScheduler: scheduler)

        monitor.refreshInterval = 600

        XCTAssertEqual(defaults.values["GithubPanel.refreshInterval"], 600)
        XCTAssertEqual(scheduler.intervals, [600])
    }

    func testStartUpdatesTokenPresenceAndSchedulesTimer() {
        let tokenStore = FakeTokenStore(token: "token")
        let scheduler = FakeTimerScheduler()
        let monitor = makeMonitor(tokenStore: tokenStore, timerScheduler: scheduler)

        monitor.start()

        XCTAssertTrue(monitor.hasToken)
        XCTAssertEqual(scheduler.intervals, [60])
    }

    func testRefreshSuccessBuildsOrderedLimitedRowsAndTimestamp() async {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let api = FakeGitHubAPI()
        api.user = GitHubUser(login: "fred")
        api.summaries = (1...12).map { index in
            summary(number: index, updatedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        for item in api.summaries {
            api.pullRequests[item.repoFullName + "#\(item.number)"] = info(number: item.number, status: .success)
        }
        let monitor = makeMonitor(api: api,
                                  tokenStore: FakeTokenStore(token: "token"),
                                  dateProvider: FakeDateProvider(now: fixedDate))

        await monitor.refreshNow()

        XCTAssertFalse(monitor.isLoading)
        XCTAssertNil(monitor.lastError)
        XCTAssertEqual(monitor.lastRefreshAt, fixedDate)
        XCTAssertEqual(monitor.prRows.map(\.number), Array(1...10))
        XCTAssertEqual(api.fetchPullRequestCalls.count, 10)
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
        api.summaries = [summary(number: 1), summary(number: 2)]
        api.pullRequests["acme/widgets#1"] = info(number: 1, status: .pending)
        api.pullRequests["acme/widgets#2"] = info(number: 2, status: .success)
        let notifications = FakeNotificationPoster()
        let monitor = makeMonitor(api: api,
                                  tokenStore: FakeTokenStore(token: "token"),
                                  notificationPoster: notifications)

        await monitor.refreshNow()
        XCTAssertTrue(notifications.posts.isEmpty)

        api.summaries = [summary(number: 1)]
        api.pullRequests["acme/widgets#1"] = info(number: 1, status: .failure)
        await monitor.refreshNow()

        XCTAssertEqual(notifications.posts.count, 1)
        XCTAssertEqual(notifications.posts[0].state, .failure)
        XCTAssertEqual(notifications.posts[0].number, 1)

        api.summaries = [summary(number: 2)]
        api.pullRequests["acme/widgets#2"] = info(number: 2, status: .success)
        await monitor.refreshNow()

        XCTAssertEqual(notifications.posts.count, 1)
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
        api.summaries = [summary(number: 1)]
        api.pullRequests["acme/widgets#1"] = info(number: 1, status: .success, inMergeQueue: true)
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let item = row(number: 1, status: .success, mergeQueue: true)

        await monitor.requestMerge(for: item)

        XCTAssertEqual(api.enqueueCalls, ["node-1"])
        XCTAssertEqual(monitor.prRows.first?.isInMergeQueue, true)
    }

    func testBlockedSuccessfulRowEnablesAutoMergeInsteadOfDirectMerge() async {
        let api = FakeGitHubAPI()
        api.user = GitHubUser(login: "fred")
        api.summaries = [summary(number: 1)]
        api.pullRequests["acme/widgets#1"] = info(number: 1,
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
        enableAPI.summaries = [summary(number: 1)]
        enableAPI.pullRequests["acme/widgets#1"] = info(number: 1, status: .pending, autoMerge: true)
        let enableMonitor = makeMonitor(api: enableAPI, tokenStore: FakeTokenStore(token: "token"))

        await enableMonitor.requestMerge(for: row(number: 1, status: .pending, canEnableAutoMerge: true))

        XCTAssertEqual(enableAPI.enableCalls, ["node-1"])
        XCTAssertEqual(enableMonitor.prRows.first?.isAutoMergeEnabled, true)

        let disableAPI = FakeGitHubAPI()
        disableAPI.user = GitHubUser(login: "fred")
        disableAPI.summaries = [summary(number: 1)]
        disableAPI.pullRequests["acme/widgets#1"] = info(number: 1, status: .pending, autoMerge: false)
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
                         dateProvider: FakeDateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))) -> PRMonitor {
    PRMonitor(api: api,
              tokenStore: tokenStore,
              notificationPoster: notificationPoster,
              defaults: defaults,
              timerScheduler: timerScheduler,
              dateProvider: dateProvider)
}

private final class FakeGitHubAPI: GitHubAPIClient {
    var user = GitHubUser(login: "fred")
    var summaries: [PullRequestSummary] = []
    var historyPages: [Int: PullRequestHistoryPage] = [:]
    var pullRequests: [String: PullRequestInfo] = [:]
    var error: Error?
    var mergeResult = true
    private let lock = NSLock()

    private(set) var fetchCurrentUserTokens: [String] = []
    private(set) var fetchPullRequestCalls: [(repoFullName: String, number: Int)] = []
    private(set) var fetchClosedPRCalls: [(page: Int, perPage: Int)] = []
    private(set) var enqueueCalls: [String] = []
    private(set) var enableCalls: [String] = []
    private(set) var disableCalls: [String] = []
    private(set) var mergePullRequestCalls: [(repoFullName: String, number: Int)] = []

    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        if let error { throw error }
        fetchCurrentUserTokens.append(token)
        return user
    }

    func fetchOpenPRs(token: String, username: String) async throws -> [PullRequestSummary] {
        if let error { throw error }
        return summaries
    }

    func fetchClosedPRs(token: String, username: String, page: Int, perPage: Int) async throws -> PullRequestHistoryPage {
        if let error { throw error }
        fetchClosedPRCalls.append((page, perPage))
        return historyPages[page] ?? PullRequestHistoryPage(rows: [],
                                                            page: page,
                                                            perPage: perPage,
                                                            totalCount: 0)
    }

    func fetchPullRequest(token: String, repoFullName: String, number: Int) async throws -> PullRequestInfo {
        if let error { throw error }
        return lock.withLock {
            fetchPullRequestCalls.append((repoFullName, number))
            return pullRequests["\(repoFullName)#\(number)"] ?? info(number: number, status: .unknown)
        }
    }

    func fetchPRCheckState(token: String, pr: PullRequestInfo) async throws -> CheckState {
        pr.status
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

    func double(forKey defaultName: String) -> Double {
        values[defaultName] ?? 0
    }

    func set(_ value: Double, forKey defaultName: String) {
        values[defaultName] = value
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

private func summary(number: Int, updatedAt: Date = Date(timeIntervalSince1970: 0)) -> PullRequestSummary {
    PullRequestSummary(id: "acme/widgets#\(number)",
                       title: "PR \(number)",
                       number: number,
                       repoFullName: "acme/widgets",
                       htmlURL: URL(string: "https://github.com/acme/widgets/pull/\(number)")!,
                       updatedAt: updatedAt)
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

private func info(number: Int,
                  status: CheckState,
                  autoMerge: Bool = false,
                  canEnableAutoMerge: Bool = false,
                  canDisableAutoMerge: Bool = false,
                  mergeQueue: Bool = false,
                  inMergeQueue: Bool = false,
                  isDraft: Bool = false,
                  mergeStateStatus: String = "CLEAN") -> PullRequestInfo {
    PullRequestInfo(nodeID: "node-\(number)",
                    title: "PR \(number)",
                    number: number,
                    repoFullName: "acme/widgets",
                    htmlURL: URL(string: "https://github.com/acme/widgets/pull/\(number)")!,
                    headSHA: "sha-\(number)",
                    isDraft: isDraft,
                    status: status,
                    isAutoMergeEnabled: autoMerge,
                    canEnableAutoMerge: canEnableAutoMerge,
                    canDisableAutoMerge: canDisableAutoMerge,
                    isMergeQueueEnabled: mergeQueue,
                    isInMergeQueue: inMergeQueue,
                    mergeStateStatus: mergeStateStatus)
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
