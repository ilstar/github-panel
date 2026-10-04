import XCTest
@testable import GithubPanel

final class AppDefaultsTests: XCTestCase {
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
