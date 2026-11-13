import XCTest
@testable import GithubPanel

final class AppDefaultsTests: XCTestCase {
    func testDetectsTestHostWithoutConfigurationFilePath() {
        XCTAssertTrue(ProcessInfo.isRunningTests(environment: ["GITHUB_PANEL_RUNNING_TESTS": "1"]))
        XCTAssertTrue(ProcessInfo.isRunningTests(environment: ["XCTestBundlePath": "/tmp/GithubPanelTests.xctest"]))
        XCTAssertTrue(ProcessInfo.isRunningTests(environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"]))
    }

    func testNormalLaunchDoesNotUseTestMode() {
        XCTAssertFalse(ProcessInfo.isRunningTests(environment: [:]))
        XCTAssertFalse(ProcessInfo.isRunningTests(environment: ["GITHUB_PANEL_RUNNING_TESTS": "0"]))
    }

    func testSharedSchemeEnablesTestModeInTheRunningHost() {
        XCTAssertEqual(ProcessInfo.processInfo.environment["GITHUB_PANEL_RUNNING_TESTS"], "1")
        XCTAssertTrue(ProcessInfo.processInfo.isRunningTests)
    }

    /// The test host shares the real app's bundle identifier, so its settings must not land in the real app's defaults.
    func testTestHostKeepsSettingsOutOfTheRealAppDefaults() {
        let key = "GithubPanelTests.appDefaults.\(UUID().uuidString)"
        defer { AppDefaults.store.removeObject(forKey: key) }

        AppDefaults.store.set("test", forKey: key)

        XCTAssertNotIdentical(AppDefaults.store, UserDefaults.standard)
        XCTAssertEqual(AppDefaults.store.string(forKey: key), "test")
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }
}
