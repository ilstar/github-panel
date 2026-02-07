import SwiftUI
import UserNotifications

@main
struct GithubPanelApp: App {
    @StateObject private var monitor = PRMonitor()

    init() {
        NotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
        }
    }
}
