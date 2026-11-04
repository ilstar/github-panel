import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorForLaterTests: XCTestCase {
    func testMovingToForLaterSplitsMyPRsAndSaves() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success), row(number: 2, status: .success)]
        let defaults = FakeDefaults()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults)
        await monitor.refreshNow()

        monitor.moveToForLater(api.rows[0])

        XCTAssertEqual(monitor.myPullRequests.active.map(\.number), [2])
        XCTAssertEqual(monitor.myPullRequests.forLater.map(\.number), [1])
        XCTAssertEqual(monitor.prRows.map(\.number), [1, 2])
        XCTAssertEqual(ForLaterStorage.decode(defaults.stringValues["GithubPanel.forLaterPullRequests"]), ["acme/widgets#1"])
    }

    func testMovingBackReturnsTheRowToMyPRs() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success), row(number: 2, status: .success)]
        let defaults = FakeDefaults()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults)
        await monitor.refreshNow()
        monitor.moveToForLater(api.rows[0])

        monitor.moveOutOfForLater(api.rows[0])

        XCTAssertEqual(monitor.myPullRequests.active.map(\.number), [1, 2])
        XCTAssertTrue(monitor.myPullRequests.forLater.isEmpty)
        XCTAssertEqual(ForLaterStorage.decode(defaults.stringValues["GithubPanel.forLaterPullRequests"]), [])
    }

    func testForLaterIsRestoredFromDefaults() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success), row(number: 2, status: .success)]
        let defaults = FakeDefaults()
        defaults.stringValues["GithubPanel.forLaterPullRequests"] = ForLaterStorage.encode(["acme/widgets#2"])
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults)

        await monitor.refreshNow()

        XCTAssertEqual(monitor.myPullRequests.active.map(\.number), [1])
        XCTAssertEqual(monitor.myPullRequests.forLater.map(\.number), [2])
    }

    func testClosedPullRequestsAreForgotten() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success), row(number: 2, status: .success)]
        let defaults = FakeDefaults()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), defaults: defaults)
        await monitor.refreshNow()
        monitor.moveToForLater(api.rows[0])

        api.rows = [row(number: 2, status: .success)]
        await monitor.refreshNow()
        XCTAssertEqual(monitor.forLaterIDs, [])

        api.rows = [row(number: 1, status: .success), row(number: 2, status: .success)]
        await monitor.refreshNow()
        XCTAssertEqual(monitor.myPullRequests.active.map(\.number), [1, 2])
    }

    func testForLaterIsKeptWhenSSOHidesSomePullRequests() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success), row(number: 2, status: .success)]
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        monitor.moveToForLater(api.rows[0])

        api.rows = [row(number: 2, status: .success)]
        api.openSSOAuthorizationURL = URL(string: "https://github.com/orgs/acme/sso")
        await monitor.refreshNow()

        XCTAssertEqual(monitor.forLaterIDs, ["acme/widgets#1"])
    }

    func testFailedRefreshKeepsForLater() async {
        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .success)]
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))
        await monitor.refreshNow()
        monitor.moveToForLater(api.rows[0])

        api.openHandler = { _ in throw TestError(message: "offline") }
        await monitor.refreshNow()

        XCTAssertEqual(monitor.forLaterIDs, ["acme/widgets#1"])
    }
}
