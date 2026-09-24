import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorActionTests: XCTestCase {
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

    func testMarkingDraftReadyCallsAPIAndRefreshesRows() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        let tokenStore = FakeTokenStore(token: "token")
        let monitor = makeMonitor(api: api, tokenStore: tokenStore)

        await monitor.requestMarkReady(for: row(number: 1, status: .pending, isDraft: true))

        XCTAssertEqual(api.markReadyCalls, ["node-1"])
        XCTAssertEqual(api.fetchOpenPRTokens, ["token"])
        XCTAssertEqual(monitor.prRows, api.rows)
        XCTAssertEqual(tokenStore.loadTokenCallCount, 1)
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

    func testMergeActionMatchesResolvedButtonState() async {
        let cases: [(PullRequestRow, MergeButtonState, String?)] = [
            (row(number: 1, status: .success), .merge, "merge"),
            (row(number: 2, status: .noChecks, mergeQueue: true), .enqueue, "enqueue"),
            (row(number: 3, status: .pending, canEnableAutoMerge: true), .enableAutoMerge, "enable"),
            (row(number: 4, status: .unknown, canEnableAutoMerge: true), .enableAutoMerge, "enable"),
            (row(number: 5, status: .pending, autoMerge: true, canDisableAutoMerge: true), .disableAutoMerge, "disable"),
            (row(number: 6, status: .success, isDraft: true), .markReady, nil),
            (row(number: 7, status: .failure, canEnableAutoMerge: true), .checksFailed, nil),
            (row(number: 8, status: .success, mergeQueue: true, inMergeQueue: true), .queued, nil),
            (row(number: 9, status: .pending), .waitingForChecks, nil),
            (row(number: 10, status: .unknown), .statusUnavailable, nil),
            (row(number: 11, status: .success, mergeStateStatus: "BLOCKED"), .blocked, nil)
        ]

        for (item, expectedState, expectedCall) in cases {
            XCTAssertEqual(MergeButtonState.resolve(for: item, isWorking: false), expectedState, "PR \(item.number)")

            let api = FakeGitHubAPI()
            let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
            await monitor.requestMerge(for: item)

            var calls: [String] = []
            if !api.mergePullRequestCalls.isEmpty { calls.append("merge") }
            if !api.enqueueCalls.isEmpty { calls.append("enqueue") }
            if !api.enableCalls.isEmpty { calls.append("enable") }
            if !api.disableCalls.isEmpty { calls.append("disable") }
            XCTAssertEqual(calls, expectedCall.map { [$0] } ?? [], "PR \(item.number)")
        }
    }

    func testMergeWithoutTokenDoesNothing() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))

        await monitor.requestMerge(for: row(number: 1, status: .success))

        XCTAssertTrue(api.mergePullRequestCalls.isEmpty)
    }
}
