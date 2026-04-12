import SwiftUI
import UserNotifications
import KeyboardShortcuts

@main
struct GithubPanelApp: App {
    @StateObject private var monitor = PRMonitor()

    init() {
        if !ProcessInfo.processInfo.isRunningTests {
            NotificationManager.shared.configure()
            KeyboardShortcuts.onKeyUp(for: .toggleApp) {
                AppVisibility.toggle()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
        }
        Settings {
            SettingsView()
                .environmentObject(monitor)
        }
    }
}

private extension ProcessInfo {
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
