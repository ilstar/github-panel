import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorPrefetchTests: XCTestCase {
    func testRefreshPrefetchesDetailsAndCommentsOfOpenPullRequests() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success), row(number: 2, status: .pending)])
        let comments = PullRequestComments(comments: [], threads: [])
        api.comments = comments
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1, 2])
        XCTAssertEqual(api.detailCalls.map(\.token), ["token", "token"])
        XCTAssertEqual(Set(api.commentsCalls.map(\.reference.number)), [1, 2])
        XCTAssertEqual(monitor.detailCache.entry(for: reference(1))?.content.detail.title, "PR 1")
        XCTAssertEqual(monitor.detailCache.entry(for: reference(2))?.comments, comments)
    }

    func testRefreshOnlyPrefetchesPullRequestsThatChanged() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success), row(number: 2, status: .success)])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        await monitor.refreshNow()
        await monitor.waitForPrefetch()
        XCTAssertEqual(api.detailCalls.count, 2, "Nothing changed")

        api.rows = [row(number: 1, status: .success),
                    row(number: 2, status: .success, updatedAt: Date(timeIntervalSince1970: 50))]
        await monitor.refreshNow()
        await monitor.waitForPrefetch()

        XCTAssertEqual(api.detailCalls.map(\.reference.number), [1, 2, 2])
        XCTAssertEqual(monitor.detailCache.entry(for: reference(2))?.content.detail.updatedAt,
                       Date(timeIntervalSince1970: 50))
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
        XCTAssertEqual(monitor.detailCache.count, 0)
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
        XCTAssertNil(monitor.detailCache.entry(for: reference(1)))
        XCTAssertNotNil(monitor.detailCache.entry(for: reference(2)))
    }

    func testChangingTheTokenEmptiesTheCache() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        await monitor.waitForPrefetch()
        XCTAssertEqual(monitor.detailCache.count, 1)

        monitor.clearToken()

        XCTAssertEqual(monitor.detailCache.count, 0)
    }

    func testPrefetchStartedBeforeTheTokenChangedIsDropped() async {
        let api = prefetchingAPI(rows: [row(number: 1, status: .success)])
        let commentsRequested = expectation(description: "Comments requested")
        let release = AsyncGate()
        api.commentsHandler = { _ in
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

        XCTAssertEqual(monitor.detailCache.count, 0)
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
