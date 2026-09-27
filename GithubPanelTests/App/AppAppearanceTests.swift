import XCTest
import AppKit
@testable import GithubPanel

final class AppAppearanceTests: XCTestCase {
    func testSettingsOffersSystemLightAndDarkInThatOrder() {
        XCTAssertEqual(AppAppearance.allCases.map(\.title), ["System", "Light", "Dark"])
    }

    func testDefaultsToSystemWhenNothingIsSaved() {
        XCTAssertEqual(AppAppearance.stored(in: FakeDefaults()), .system)
    }

    func testReadsTheSavedChoice() {
        let defaults = FakeDefaults()
        defaults.set("dark", forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .dark)
    }

    func testFallsBackToSystemForAnUnknownValue() {
        let defaults = FakeDefaults()
        defaults.set("sepia", forKey: AppAppearance.defaultsKey)
        XCTAssertEqual(AppAppearance.stored(in: defaults), .system)
    }

    func testSystemFollowsMacOSAndTheOthersForceAnAppearance() {
        XCTAssertNil(AppAppearance.system.appearanceName)
        XCTAssertEqual(AppAppearance.light.appearanceName, .aqua)
        XCTAssertEqual(AppAppearance.dark.appearanceName, .darkAqua)
    }

    @MainActor
    func testApplyingSetsAndClearsTheAppAppearance() {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }

        AppAppearance.dark.apply(to: application)
        XCTAssertEqual(application.appearance?.name, .darkAqua)

        AppAppearance.light.apply(to: application)
        XCTAssertEqual(application.appearance?.name, .aqua)

        AppAppearance.system.apply(to: application)
        XCTAssertNil(application.appearance)
    }
}
