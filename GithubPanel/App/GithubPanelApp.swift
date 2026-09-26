import SwiftUI
import AppKit
import UserNotifications
import KeyboardShortcuts
import Sparkle

@main
struct GithubPanelApp: App {
    @StateObject private var monitor: PRMonitor
    private let updaterController: SPUStandardUpdaterController

    init() {
        let monitor = Self.makeMonitor()
        _monitor = StateObject(wrappedValue: monitor)
        updaterController = SPUStandardUpdaterController(startingUpdater: false,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: nil)

        if !ProcessInfo.processInfo.isRunningTests {
            NotificationManager.shared.configure()
            KeyboardShortcuts.onKeyUp(for: .toggleApp) {
                AppVisibility.toggle()
            }
        }

        if Self.shouldStartUpdater {
            updaterController.startUpdater()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(monitor)
        }
        .commands {
            CommandMenu("Pull Requests") {
                ForEach(PullRequestTab.allCases) { tab in
                    Button(tab.title) {
                        monitor.selectedTab = tab
                    }
                    .keyboardShortcut(tab.shortcutKey, modifiers: .command)
                }

                Divider()

                Button("Refresh") {
                    Task { await monitor.refreshSelectedTab() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!monitor.hasToken || monitor.isSelectedTabLoading)
            }
        }
        WindowGroup("Pull Request", for: PullRequestReference.self) { $reference in
            if let reference {
                PullRequestDetailView(viewModel: PullRequestDetailViewModel(reference: reference) { [monitor] reference in
                    try await monitor.fetchPullRequestDetail(reference)
                })
            }
        }
        .defaultSize(width: 960, height: 760)
        Settings {
            SettingsView()
                .environmentObject(monitor)
        }
        .commandsReplaced {
            CommandGroup(replacing: .appSettings) {
                if #available(macOS 14.0, *) {
                    SettingsLink()
                        .keyboardShortcut(",", modifiers: .command)
                } else {
                    Button("Settings…") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }

                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
                .disabled(!updaterController.updater.canCheckForUpdates)
            }
        }
    }

    @MainActor
    private static func makeMonitor() -> PRMonitor {
        if ProcessInfo.processInfo.isRunningTests {
            return PRMonitor(tokenStore: InMemoryTokenStore())
        }

        #if DEBUG
        if ProcessInfo.processInfo.usesMockGitHubPRs {
            return PRMonitor(api: MockGitHubAPI(isEmpty: ProcessInfo.processInfo.usesEmptyMockGitHubPRs),
                             tokenStore: MockTokenStore(),
                             isUsingMockData: true)
        }
        #endif

        return PRMonitor()
    }

    private static var shouldStartUpdater: Bool {
        #if DEBUG
        false
        #else
        !ProcessInfo.processInfo.isRunningTests
        #endif
    }

}

private extension ProcessInfo {
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    #if DEBUG
    var usesMockGitHubPRs: Bool {
        arguments.contains("--mock-github-prs")
        || usesEmptyMockGitHubPRs
        || environment["GITHUB_PANEL_MOCK_PRS"] == "1"
        || UserDefaults.standard.bool(forKey: "GithubPanel.useMockGitHubPRs")
    }

    var usesEmptyMockGitHubPRs: Bool {
        arguments.contains("--mock-empty-github-prs")
        || environment["GITHUB_PANEL_MOCK_EMPTY_PRS"] == "1"
    }
    #endif
}
