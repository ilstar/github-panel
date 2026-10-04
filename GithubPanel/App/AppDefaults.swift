import Foundation

/// The defaults the app keeps its settings in. Under XCTest the test host gets a throwaway store of its own, so a
/// test run, including several at once from different checkouts, never reads or changes the settings of the app
/// you use, which shares the test host's bundle identifier.
enum AppDefaults {
    static let store: UserDefaults = ProcessInfo.processInfo.isRunningTests ? makeTestStore() : .standard

    private static func makeTestStore() -> UserDefaults {
        // A suite name that is an absolute path keeps the defaults in that file instead of ~/Library/Preferences.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("GithubPanelTests-\(UUID().uuidString)").path
        return UserDefaults(suiteName: path) ?? .standard
    }
}

extension ProcessInfo {
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
