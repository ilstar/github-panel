import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorTransitionTests: XCTestCase {
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
}
