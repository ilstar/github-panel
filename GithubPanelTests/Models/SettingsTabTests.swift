import XCTest
@testable import GithubPanel

final class SettingsTabTests: XCTestCase {
    func testTabsAppearInToolbarOrder() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.title),
            ["General", "Account", "Notifications", "Extensions", "Hooks"]
        )
    }

    func testEveryTabHasAnIcon() {
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.systemImage.isEmpty, "\(tab) has no icon")
        }
    }

    func testDefaultsToGeneralWhenNothingIsSaved() {
        XCTAssertEqual(SettingsTab.stored(in: FakeDefaults()), .general)
    }

    func testReadsTheSavedTab() {
        let defaults = FakeDefaults()
        defaults.set("hooks", forKey: SettingsTab.defaultsKey)
        XCTAssertEqual(SettingsTab.stored(in: defaults), .hooks)
    }

    func testFallsBackToGeneralForAnUnknownValue() {
        let defaults = FakeDefaults()
        defaults.set("advanced", forKey: SettingsTab.defaultsKey)
        XCTAssertEqual(SettingsTab.stored(in: defaults), .general)
    }
}
