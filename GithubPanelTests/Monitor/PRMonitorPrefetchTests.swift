import XCTest
import Combine
@testable import GithubPanel

@MainActor
final class PRMonitorPrefetchTests: XCTestCase {
    func testRefreshPrefetchesDetailsCommentsAndChecksOfOpenPullRequests() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success), row(number: 2, status: .pending)])
        let comments = PullRequestComments(comments: [], threads: [])
        api.comments = comments
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1, 2])
        XCTAssertEqual(api.detailCalls.map(\.token), ["token", "token"])
        XCTAssertEqual(Set(api.commentsCalls.map(\.reference.number)), [1, 2])
        XCTAssertEqual(Set(api.checksCalls.map(\.reference.number)), [1, 2])
        XCTAssertNotNil(monitor.cache.entry(for: reference(1))?.checks)
        XCTAssertEqual(monitor.cache.entry(for: reference(1))?.content.detail.title, "PR 1")
        XCTAssertEqual(monitor.cache.entry(for: reference(2))?.comments, comments)
    }

    func testPreloadFetchesChecksAlongsideTheContent() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        var checksStartedBeforeContentLoaded = false
        api.detailHandler = { [api] reference in
            for _ in 0..<100 where !api.checksCalls.contains(where: { $0.reference == reference }) {
                await Task.yield()
            }
            checksStartedBeforeContentLoaded = api.checksCalls.contains { $0.reference == reference }
            return detailContent(for: reference, title: "PR \(reference.number)")
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertTrue(checksStartedBeforeContentLoaded)
        XCTAssertNotNil(monitor.cache.entry(for: reference(1))?.checks)
    }

    func testPreloadKeepsTheContentWhenChecksFail() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        api.checksHandler = { _ in throw TestError(message: "Checks unavailable") }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertEqual(monitor.cache.entry(for: reference(1))?.content.detail.title, "PR 1")
        XCTAssertNil(monitor.cache.entry(for: reference(1))?.checks)
    }

    func testRefreshOnlyPrefetchesPullRequestsThatChanged() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success), row(number: 2, status: .success)])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        await monitor.refreshNow()
        await monitor.waitForPrefetch()
        XCTAssertEqual(api.detailCalls.count, 2, "Nothing changed")
        XCTAssertEqual(api.checksCalls.count, 4, "Checks refresh even without a PR update")

        api.rows = [row(number: 1, status: .success),
                    row(number: 2, status: .success, updatedAt: Date(timeIntervalSince1970: 50))]
        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1, 2, 2])
        XCTAssertEqual(monitor.cache.entry(for: reference(2))?.content.detail.updatedAt,
                       Date(timeIntervalSince1970: 50))
    }

    func testBothReviewGroupsArePreloadedAndOverlapIsDeduplicated() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1), reviewRequestRow(number: 2)],
                                           fromMyTeams: [reviewRequestRow(number: 3)])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1, 2, 3])
        XCTAssertEqual(api.checksCalls.map(\.reference.number), [1, 2, 3])
        XCTAssertNotNil(monitor.cache.entry(for: reference(3))?.comments)
    }

    func testPreloadTakesTheTopRowsOfBothTabsFirst() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success), row(number: 2, status: .success),
                                        row(number: 3, status: .success)])
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 8)],
                                           fromMyTeams: [reviewRequestRow(number: 7)])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1, 8, 2, 7, 3])
    }

    func testStandaloneReviewRefreshPreloadsDetails() async {
        let api = prefetchingAPI(rows: [])
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 2)], fromMyTeams: [])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshReviewRequests()
        await monitor.waitForPrefetch()
        XCTAssertEqual(api.detailCalls.map(\.reference.number), [2])
        XCTAssertNotNil(monitor.cache.entry(for: reference(2))?.checks)
    }

    func testBackgroundRefreshUpdatesOpenDetailsAndChecksWithoutUpdatedAtChanging() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .pending)])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await monitor.waitForPrefetch()
        let open = PullRequestDetailViewModel(reference: reference(1), monitor: monitor)
        let unrelated = PullRequestDetailViewModel(reference: reference(2), monitor: monitor)
        let checks = PullRequestChecks(checks: [PullRequestCheck(id: "ci", name: "CI", workflowName: nil,
            outcome: .success, summary: nil, startedAt: nil, completedAt: nil, detailsURL: nil)])
        api.checks = checks
        await monitor.refreshNow()
        await monitor.waitForPrefetch()
        XCTAssertEqual(open.checks, checks)
        XCTAssertEqual(api.detailCalls.count, 1)
        XCTAssertNil(unrelated.content)

        api.rows = [row(number: 1, status: .success, updatedAt: Date(timeIntervalSince1970: 50))]
        api.detailHandler = { reference in
            detailContent(for: reference, title: "Updated in background", updatedAt: Date(timeIntervalSince1970: 50))
        }
        let comments = PullRequestComments(comments: [], threads: [], totalCommentCount: 7)
        api.comments = comments
        await monitor.refreshNow()
        await monitor.waitForPrefetch()
        XCTAssertEqual(open.content?.detail.title, "Updated in background")
        XCTAssertEqual(open.comments, comments)
        XCTAssertEqual(open.checks, checks)
    }

    func testOpeningAPullRequestWhileItPreloadsJoinsThePreload() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        let requested = expectation(description: "Detail requested")
        let gate = AsyncGate()
        api.detailHandler = { reference in
            requested.fulfill()
            await gate.wait()
            return detailContent(for: reference, title: "Preloaded")
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await fulfillment(of: [requested], timeout: 5)

        let viewModel = PullRequestDetailViewModel(reference: reference(1), monitor: monitor)
        let opened = Task { await viewModel.load(maxAge: PullRequestDetailViewModel.openMaxAge) }
        await gate.open()
        await opened.value
        await monitor.waitForPrefetch()

        XCTAssertEqual(api.detailCalls.count, 1)
        XCTAssertEqual(api.commentsCalls.count, 1)
        XCTAssertEqual(viewModel.content?.detail.title, "Preloaded")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRefreshDuringPreloadQueuesNewRows() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        let requested = expectation(description: "First detail request")
        let gate = AsyncGate()
        var first = true
        api.detailHandler = { reference in
            if first {
                first = false
                requested.fulfill()
                await gate.wait()
            }
            return detailContent(for: reference, updatedAt: Date(timeIntervalSince1970: 1))
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await fulfillment(of: [requested], timeout: 5)
        api.rows = [row(number: 2, status: .success)]
        await monitor.refreshNow()
        await gate.open()
        await monitor.waitForPrefetch()
        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1, 2])
    }

    func testRefreshButtonShowsFetchingAndSpinsWhileTheListsLoad() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        let requested = expectation(description: "Open list requested")
        let gate = AsyncGate()
        api.openHandler = { [api] _ in
            requested.fulfill()
            await gate.wait()
            return OpenPullRequests(login: "fred", rows: api.rows)
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        let refresh = Task { await monitor.refreshNow() }
        await fulfillment(of: [requested], timeout: 5)

        XCTAssertTrue(monitor.isLoading)
        XCTAssertEqual(monitor.refreshProgressText, "Fetching PR lists…")
        XCTAssertTrue(monitor.isSelectedTabRefreshing)
        XCTAssertTrue(monitor.isSelectedTabBusy)
        monitor.selectedTab = .reviews
        XCTAssertEqual(monitor.refreshProgressText, "Fetching PR lists…")
        XCTAssertTrue(monitor.isSelectedTabRefreshing)

        await gate.open()
        await refresh.value
        await monitor.waitForPrefetch()
        XCTAssertFalse(monitor.isSelectedTabBusy)
        XCTAssertNil(monitor.refreshProgressText)
        XCTAssertFalse(monitor.isSelectedTabRefreshing)
    }

    func testFetchingIndicatorWaitsForReviewRequestsAndClearsAfterFailure() async {
        let api = prefetchingAPI(rows: [])
        let requested = expectation(description: "Review requests requested")
        let gate = AsyncGate()
        api.reviewRequestsHandler = { _ in
            requested.fulfill()
            await gate.wait()
            throw TestError(message: "Reviews offline")
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        let refresh = Task { await monitor.refreshNow() }
        await fulfillment(of: [requested], timeout: 5)

        XCTAssertEqual(monitor.refreshProgressText, "Fetching PR lists…")
        XCTAssertTrue(monitor.isSelectedTabRefreshing)

        await gate.open()
        await refresh.value
        await monitor.waitForPrefetch()

        XCTAssertNil(monitor.refreshProgressText)
        XCTAssertFalse(monitor.isSelectedTabRefreshing)
        XCTAssertFalse(monitor.isSelectedTabBusy)
        XCTAssertNotNil(monitor.lastReviewRequestsError)
    }

    func testRefreshStaysBusyFromLoadingTheListsUntilTheCountsShow() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        let requested = expectation(description: "Detail requested")
        let gate = AsyncGate()
        api.detailHandler = { reference in
            requested.fulfill()
            await gate.wait()
            return detailContent(for: reference, title: "PR \(reference.number)")
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        var busyChanges: [Bool] = []
        let subscription = monitor.$isRefreshingLists.dropFirst().removeDuplicates().sink { busyChanges.append($0) }

        await monitor.refreshNow()
        await fulfillment(of: [requested], timeout: 5)

        // The lists finished loading before the counts started, without the refresh going idle in between.
        XCTAssertEqual(busyChanges, [true, false])
        XCTAssertNotNil(monitor.refreshProgressText)
        XCTAssertTrue(monitor.isSelectedTabBusy)
        await gate.open()
        await monitor.waitForPrefetch()
        subscription.cancel()
    }

    func testATimerTickThatFindsTheListsFreshLeavesTheButtonStill() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        let dateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dateProvider)
        await monitor.refreshNow()
        await monitor.waitForPrefetch()
        var busyChanges: [Bool] = []
        let subscription = monitor.$isRefreshingLists.dropFirst().sink { busyChanges.append($0) }

        dateProvider.now = Date(timeIntervalSince1970: 1)
        await monitor.refreshScheduler.handleTimerTick()

        XCTAssertEqual(api.fetchOpenPRTokens.count, 1)
        XCTAssertFalse(busyChanges.contains(true))
        XCTAssertFalse(monitor.isSelectedTabBusy)
        subscription.cancel()
    }

    func testRefreshButtonShowsPreloadProgressUntilItFinishes() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success), row(number: 2, status: .success)])
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 8)], fromMyTeams: [])
        let requested = expectation(description: "First detail request")
        let gate = AsyncGate()
        api.detailHandler = { reference in
            if reference.number == 1 {
                requested.fulfill()
                await gate.wait()
            }
            return detailContent(for: reference, title: "PR \(reference.number)")
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        XCTAssertNil(monitor.refreshProgressText)

        await monitor.refreshNow()
        await fulfillment(of: [requested], timeout: 5)

        XCTAssertEqual(monitor.refreshProgressText, "Refreshing My PRs 1/2…")
        XCTAssertTrue(monitor.isSelectedTabRefreshing)
        monitor.selectedTab = .reviews
        XCTAssertEqual(monitor.refreshProgressText, "Refreshing To Review 1/1…")

        await gate.open()
        await monitor.waitForPrefetch()

        XCTAssertNil(monitor.refreshProgress)
        XCTAssertNil(monitor.refreshProgressText)
        XCTAssertFalse(monitor.isSelectedTabRefreshing)
    }

    func testPrefetchPreservesExpandedDiscussionLimits() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await monitor.waitForPrefetch()
        let limits = PullRequestCommentLimits().addingEarlierComments().addingThreads()
        monitor.cache.store(.empty, for: reference(1), limits: limits)
        api.rows = [row(number: 1, status: .success, updatedAt: Date(timeIntervalSince1970: 50))]

        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertEqual(monitor.cache.entry(for: reference(1))?.commentLimits, limits)
    }

    func testPrefetchStopsWhenGitHubThrottles() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success), row(number: 2, status: .success)])
        api.detailHandler = { _ in
            throw GitHubAPIError(message: "Rate limited", documentationURL: nil, statusCode: 403)
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1])
        XCTAssertEqual(monitor.cache.detailCount, 0)
        XCTAssertNil(monitor.lastError)
    }

    func testFailedPrefetchSkipsThatPullRequestAndKeepsTheList() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success), row(number: 2, status: .success)])
        api.detailHandler = { reference in
            guard reference.number == 2 else { throw TestError(message: "Not found") }
            return detailContent(for: reference, updatedAt: Date(timeIntervalSince1970: 2))
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertEqual(monitor.prRows.map(\.number), [1, 2])
        XCTAssertNil(monitor.lastError)
        XCTAssertNil(monitor.cache.entry(for: reference(1)))
        XCTAssertNotNil(monitor.cache.entry(for: reference(2)))
    }

    func testChangingTheTokenEmptiesTheCache() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await monitor.waitForPrefetch()
        XCTAssertEqual(monitor.cache.detailCount, 1)

        monitor.clearToken()

        XCTAssertEqual(monitor.cache.detailCount, 0)
    }

    func testPrefetchStartedBeforeTheTokenChangedIsDropped() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        let commentsRequested = expectation(description: "Comments requested")
        let release = AsyncGate()
        api.commentsHandler = { _, _ in
            commentsRequested.fulfill()
            await release.wait()
            return .empty
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await fulfillment(of: [commentsRequested], timeout: 5)

        monitor.clearToken()
        await release.open()
        // Let the prefetch finish its request before checking it stored nothing.
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(monitor.cache.detailCount, 0)
    }

    func testRefreshPreloadsOnlyTheCurrentPagesOfBothLists() async {
        let api = prefetchingAPI(rows: (1...55).map { row(number: $0, status: .success) })
        api.reviewRequests = ReviewRequests(fromMe: (101...108).map { reviewRequestRow(number: $0) },
                                           fromMyTeams: (109...115).map { reviewRequestRow(number: $0) })
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        let expected = Set(Array(1...50) + Array(101...110))
        XCTAssertEqual(Set(api.detailCalls.map(\.reference.number)), expected)
        XCTAssertEqual(Set(api.commentsCalls.map(\.reference.number)), expected)
        XCTAssertEqual(Set(api.checksCalls.map(\.reference.number)), expected)
        XCTAssertEqual(monitor.openTotalCount, 55)
        XCTAssertEqual(monitor.reviewPage.totalCount, 15)

        monitor.showOpenPage(2)
        monitor.showReviewPage(2)
        await monitor.waitForPrefetch()
        let pageTwo = Set(Array(51...55) + Array(111...115))
        XCTAssertTrue(pageTwo.isSubset(of: Set(api.detailCalls.map(\.reference.number))))

        let checksBeforeRefresh = api.checksCalls.count
        await monitor.refreshNow()
        await monitor.waitForPrefetch()
        XCTAssertEqual(Set(api.checksCalls.dropFirst(checksBeforeRefresh).map(\.reference.number)), pageTwo)
    }

    func testChangingPagesDropsRowsStillWaitingToPreload() async {
        let api = prefetchingAPI(rows: (1...55).map { row(number: $0, status: .success) })
        let requested = expectation(description: "First row started")
        let gate = AsyncGate()
        api.detailHandler = { reference in
            if reference.number == 1 {
                requested.fulfill()
                await gate.wait()
            }
            return detailContent(for: reference)
        }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await fulfillment(of: [requested], timeout: 5)

        monitor.showOpenPage(2)
        XCTAssertEqual(monitor.refreshProgress?.count(of: .myPullRequests).total, 5)
        await gate.open()
        await monitor.waitForPrefetch()

        XCTAssertEqual(Set(api.detailCalls.map(\.reference.number)), Set([1] + Array(51...55)))
        XCTAssertEqual(Set(api.commentsCalls.map(\.reference.number)), Set([1] + Array(51...55)))
        XCTAssertEqual(Set(api.checksCalls.map(\.reference.number)), Set([1] + Array(51...55)))
        XCTAssertNil(monitor.refreshProgress)
    }

    private func prefetchingAPI(rows: [PullRequestRow]) -> FakeGitHubAPI {
        let api = FakeGitHubAPI()
        api.rows = rows
        api.detailHandler = { [api] reference in
            let row = api.rows.first { $0.number == reference.number }
            return detailContent(for: reference, title: "PR \(reference.number)", updatedAt: row?.updatedAt)
        }
        return api
    }

    private func reference(_ number: Int) -> PullRequestReference {
        PullRequestReference(repoFullName: "acme/widgets", number: number)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
