import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorSettingsTests: XCTestCase {
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
        monitor.start()

        XCTAssertTrue(monitor.hasToken)
        XCTAssertEqual(scheduler.intervals, [60, 60])
        XCTAssertEqual(tokenStore.loadTokenCallCount, 1)
    }
}
