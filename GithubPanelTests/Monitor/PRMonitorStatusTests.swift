import XCTest
@testable import GithubPanel

/// Every list shows the newest status any load saw for a pull request, so a detail or checks load updates its row.
@MainActor
final class PRMonitorStatusTests: XCTestCase {
    private let reference = PullRequestReference(repoFullName: "acme/widgets", number: 1)

    func testANewHeadFromTheDetailShowsInMyPRsWithItsChecksPending() async throws {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        monitor.cache.store(OpenPullRequests(login: "fred", rows: [row(number: 1, status: .failure)]),
                                fetchedAt: Date(timeIntervalSince1970: 0))
        api.detailHandler = { [self] _ in content(headSHA: "merged") }

        try await monitor.syncEngine.request(.detail(reference))

        XCTAssertEqual(monitor.prRows.map(\.headSHA), ["merged"])
        XCTAssertEqual(monitor.prRows.map(\.status), [.pending])
    }

    func testChecksFromTheDetailShowInMyPRs() async throws {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        monitor.cache.store(OpenPullRequests(login: "fred", rows: [row(number: 1, status: .failure)]),
                                fetchedAt: Date(timeIntervalSince1970: 0))
        api.detailHandler = { [self] _ in content(headSHA: "sha-1") }
        api.checksHandler = { _ in
            PullRequestChecks(checks: [PullRequestCheck(id: "a", name: "a", workflowName: nil, outcome: .success,
                                                        summary: nil, startedAt: nil, completedAt: nil,
                                                        detailsURL: nil, rerun: nil)])
        }

        try await monitor.syncEngine.request(.detail(reference))
        XCTAssertEqual(monitor.prRows.map(\.status), [.failure], "The detail alone says nothing about the checks")
        try await monitor.syncEngine.request(.checks(reference))

        XCTAssertEqual(monitor.prRows.map(\.status), [.success])
    }

    func testAListSentBeforeTheDetailDoesNotBringTheOldHeadBack() async throws {
        let api = FakeGitHubAPI()
        let dates = FakeDateProvider(now: Date(timeIntervalSince1970: 1))
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), dateProvider: dates)
        let gate = SuspendedOpenRequests()
        api.openHandler = { _ in try await gate.next() }
        api.detailHandler = { [self] _ in content(headSHA: "merged") }

        let list = Task { try await monitor.syncEngine.request(.openList) }
        await gate.waitForRequestCount(1)
        dates.now = Date(timeIntervalSince1970: 2)
        try await monitor.syncEngine.request(.detail(reference))
        await gate.resumeNext(returning: OpenPullRequests(login: "fred", rows: [row(number: 1, status: .failure)]))
        try await list.value

        XCTAssertEqual(monitor.prRows.map(\.headSHA), ["merged"])
        XCTAssertEqual(monitor.prRows.map(\.status), [.pending])

        dates.now = Date(timeIntervalSince1970: 3)
        var updated = row(number: 1, status: .success)
        updated.headSHA = "merged"
        api.openHandler = { _ in OpenPullRequests(login: "fred", rows: [updated]) }
        try await monitor.syncEngine.request(.openList)

        XCTAssertEqual(monitor.prRows.map(\.status), [.success], "A list sent after the detail wins")
    }

    func testTheNewestStatusShowsAfterARestart() async throws {
        let api = FakeGitHubAPI()
        let store = LocalStore.inMemory()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), store: store)
        monitor.cache.store(OpenPullRequests(login: "fred", rows: [row(number: 1, status: .failure)]),
                                fetchedAt: Date(timeIntervalSince1970: 0))
        api.detailHandler = { [self] _ in content(headSHA: "merged") }
        try await monitor.syncEngine.request(.detail(reference))

        let restarted = makeMonitor(store: store)

        XCTAssertEqual(restarted.prRows.map(\.headSHA), ["merged"])
        XCTAssertEqual(restarted.prRows.map(\.status), [.pending])
    }

    func testUpdateBranchWaitsForTheNewHeadBeforeRefreshingTheList() async throws {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        monitor.branchUpdatePollDelays = [0, 0, 0, 0]
        monitor.cache.store(OpenPullRequests(login: "fred", rows: [row(number: 1, status: .failure)]),
                                fetchedAt: Date(timeIntervalSince1970: 0))
        var events: [String] = []
        api.detailHandler = { [self] _ in
            // GitHub makes the merge commit a moment after it answers.
            let head = events.filter { $0.hasPrefix("detail") }.count < 2 ? "sha-1" : "merged"
            events.append("detail \(head)")
            return content(headSHA: head)
        }
        var updated = row(number: 1, status: .pending)
        updated.headSHA = "merged"
        api.openHandler = { _ in
            events.append("list")
            return OpenPullRequests(login: "fred", rows: [updated])
        }

        try await monitor.updatePullRequestBranch(reference, pullRequestID: "node-1", expectedHeadSHA: "sha-1")

        XCTAssertEqual(Array(events.prefix(4)), ["detail sha-1", "detail sha-1", "detail merged", "list"])
        XCTAssertEqual(monitor.prRows.map(\.headSHA), ["merged"])
        XCTAssertEqual(monitor.prRows.map(\.status), [.pending])
    }

    private func content(headSHA: String) -> PullRequestDetailContent {
        PullRequestDetailContent(
            detail: PullRequestDetail(reference: reference, nodeID: "node-1", title: "PR 1", body: "",
                                      authorLogin: "fred", state: .open, baseRef: "main", headRef: "feature",
                                      headSHA: headSHA, htmlURL: URL(string: "https://github.com/acme/widgets/pull/1")!,
                                      createdAt: Date(timeIntervalSince1970: 0), additions: 0, deletions: 0,
                                      changedFiles: 0, commits: 1),
            files: [])
    }
}
