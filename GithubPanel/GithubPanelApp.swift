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
                Button("Open Pull Requests") {
                    Self.selectPullRequestTab(.open, using: monitor)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("History") {
                    Self.selectPullRequestTab(.history, using: monitor)
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()

                Button("Refresh Pull Requests") {
                    Self.refreshPullRequests(using: monitor)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!monitor.hasToken || monitor.isLoading)
            }
        }
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

    private static func refreshPullRequests(using monitor: PRMonitor) {
        Task { @MainActor in
            await monitor.refreshNow()
        }
    }

    private static func selectPullRequestTab(_ tab: PullRequestTab, using monitor: PRMonitor) {
        Task { @MainActor in
            monitor.selectedTab = tab
            if tab == .history {
                monitor.loadHistoryIfNeeded()
            }
        }
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

#if DEBUG
final class MockTokenStore: TokenStoring {
    private var token: String? = "mock-github-token"

    var hasToken: Bool {
        token != nil
    }

    func saveToken(_ token: String) {
        self.token = token
    }

    func loadToken() -> String? {
        token
    }

    func clearToken() {
        token = nil
    }
}

final class MockGitHubAPI: GitHubAPIClient {
    private let user = GitHubUser(login: "mock-user")
    private var pullRequests: [String: PullRequestRow]
    private let history: [PullRequestHistoryRow]

    init(now: Date = Date(), isEmpty: Bool = false) {
        let rows = isEmpty ? [] : Self.makePullRequests().map {
            $0.copy(updatedAt: now.addingTimeInterval(TimeInterval(-$0.number * 70)))
        }
        self.pullRequests = Dictionary(uniqueKeysWithValues: rows.map { ("\($0.repoFullName)#\($0.number)", $0) })
        self.history = isEmpty ? [] : Self.makeHistory(now: now)
    }

    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        user
    }

    func fetchOpenPRs(token: String) async throws -> OpenPullRequests {
        let rows = pullRequests.values.sorted { $0.updatedAt > $1.updatedAt }
        return OpenPullRequests(login: user.login, rows: Array(rows.prefix(10)))
    }

    func fetchClosedPRs(token: String, username: String, page: Int, perPage: Int) async throws -> PullRequestHistoryPage {
        let safePage = max(1, page)
        let safePerPage = max(1, perPage)
        let start = (safePage - 1) * safePerPage
        let rows = start >= history.count ? [] : Array(history.dropFirst(start).prefix(safePerPage))
        return PullRequestHistoryPage(rows: rows,
                                      page: safePage,
                                      perPage: safePerPage,
                                      totalCount: history.count)
    }

    func enqueuePullRequest(token: String, pullRequestID: String) async throws {
        updatePullRequest(with: pullRequestID) { pr in
            pr.copy(isInMergeQueue: true, mergeStateStatus: "QUEUED")
        }
    }

    func enableAutoMerge(token: String, pullRequestID: String) async throws {
        updatePullRequest(with: pullRequestID) { pr in
            pr.copy(isAutoMergeEnabled: true, canEnableAutoMerge: false, canDisableAutoMerge: true)
        }
    }

    func disableAutoMerge(token: String, pullRequestID: String) async throws {
        updatePullRequest(with: pullRequestID) { pr in
            pr.copy(isAutoMergeEnabled: false, canEnableAutoMerge: true, canDisableAutoMerge: false)
        }
    }

    func mergePullRequest(token: String, repoFullName: String, number: Int) async throws -> Bool {
        pullRequests.removeValue(forKey: "\(repoFullName)#\(number)")
        return true
    }

    private func updatePullRequest(with nodeID: String, transform: (PullRequestRow) -> PullRequestRow) {
        guard let match = pullRequests.first(where: { $0.value.nodeID == nodeID }) else { return }
        pullRequests[match.key] = transform(match.value)
    }

    private static func makePullRequests() -> [PullRequestRow] {
        [
            pullRequest(number: 101,
                        title: "Ready: merge button",
                        status: .success),
            pullRequest(number: 102,
                        title: "Pending: enable auto-merge",
                        status: .pending,
                        canEnableAutoMerge: true),
            pullRequest(number: 103,
                        title: "Pending: disable auto-merge",
                        status: .pending,
                        isAutoMergeEnabled: true,
                        canDisableAutoMerge: true),
            pullRequest(number: 104,
                        title: "Ready: merge queue enabled",
                        status: .success,
                        isMergeQueueEnabled: true,
                        mergeStateStatus: "CLEAN"),
            pullRequest(number: 105,
                        title: "Already in merge queue",
                        status: .success,
                        isMergeQueueEnabled: true,
                        isInMergeQueue: true,
                        mergeStateStatus: "QUEUED"),
            pullRequest(number: 106,
                        title: "Checks failed",
                        status: .failure,
                        mergeStateStatus: "DIRTY"),
            pullRequest(number: 107,
                        title: "Checks errored",
                        status: .error,
                        mergeStateStatus: "BLOCKED"),
            pullRequest(number: 108,
                        title: "Waiting: auto-merge unavailable",
                        status: .pending),
            pullRequest(number: 109,
                        title: "Draft: success but not mergeable",
                        status: .success,
                        isDraft: true),
            pullRequest(number: 110,
                        title: "Unknown check state",
                        status: .unknown)
        ]
    }

    private static func makeHistory(now: Date) -> [PullRequestHistoryRow] {
        (1...24).map { index in
            let number = 200 - index
            let mergedAt = index % 4 == 0 ? nil : now.addingTimeInterval(TimeInterval(-index * 86_400))
            let closedAt = mergedAt ?? now.addingTimeInterval(TimeInterval(-index * 86_400))
            return PullRequestHistoryRow(id: "mock/github-panel#\(number)",
                                         title: index % 4 == 0 ? "Closed: explored alternate flow \(number)" : "Merged: shipped update \(number)",
                                         number: number,
                                         repoFullName: "mock/github-panel",
                                         htmlURL: URL(string: "https://github.com/mock/github-panel/pull/\(number)")!,
                                         updatedAt: closedAt,
                                         closedAt: closedAt,
                                         mergedAt: mergedAt)
        }
    }

    private static func pullRequest(number: Int,
                                    title: String,
                                    status: CheckState,
                                    isDraft: Bool = false,
                                    isAutoMergeEnabled: Bool = false,
                                    canEnableAutoMerge: Bool = false,
                                    canDisableAutoMerge: Bool = false,
                                    isMergeQueueEnabled: Bool = false,
                                    isInMergeQueue: Bool = false,
                                    mergeStateStatus: String = "CLEAN") -> PullRequestRow {
        PullRequestRow(id: "mock/github-panel#\(number)",
                        nodeID: "mock-node-\(number)",
                        title: title,
                        number: number,
                        repoFullName: "mock/github-panel",
                        htmlURL: URL(string: "https://github.com/mock/github-panel/pull/\(number)")!,
                        headSHA: "mock-sha-\(number)",
                        status: status,
                        isDraft: isDraft,
                        isAutoMergeEnabled: isAutoMergeEnabled,
                        canEnableAutoMerge: canEnableAutoMerge,
                        canDisableAutoMerge: canDisableAutoMerge,
                        isMergeQueueEnabled: isMergeQueueEnabled,
                        isInMergeQueue: isInMergeQueue,
                        mergeStateStatus: mergeStateStatus,
                        updatedAt: Date(timeIntervalSince1970: 0))
    }
}

private extension PullRequestRow {
    func copy(isAutoMergeEnabled: Bool? = nil,
              canEnableAutoMerge: Bool? = nil,
              canDisableAutoMerge: Bool? = nil,
              isInMergeQueue: Bool? = nil,
              mergeStateStatus: String? = nil,
              updatedAt: Date? = nil) -> PullRequestRow {
        PullRequestRow(id: id,
                         nodeID: nodeID,
                        title: title,
                        number: number,
                        repoFullName: repoFullName,
                        htmlURL: htmlURL,
                        headSHA: headSHA,
                        status: status,
                        isDraft: isDraft,
                        isAutoMergeEnabled: isAutoMergeEnabled ?? self.isAutoMergeEnabled,
                        canEnableAutoMerge: canEnableAutoMerge ?? self.canEnableAutoMerge,
                        canDisableAutoMerge: canDisableAutoMerge ?? self.canDisableAutoMerge,
                        isMergeQueueEnabled: isMergeQueueEnabled,
                        isInMergeQueue: isInMergeQueue ?? self.isInMergeQueue,
                        mergeStateStatus: mergeStateStatus ?? self.mergeStateStatus,
                        updatedAt: updatedAt ?? self.updatedAt)
    }
}
#endif
