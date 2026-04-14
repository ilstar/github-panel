import SwiftUI
import UserNotifications
import KeyboardShortcuts

@main
struct GithubPanelApp: App {
    @StateObject private var monitor: PRMonitor

    init() {
        let monitor = Self.makeMonitor()
        _monitor = StateObject(wrappedValue: monitor)

        if !ProcessInfo.processInfo.isRunningTests {
            NotificationManager.shared.configure()
            KeyboardShortcuts.onKeyUp(for: .toggleApp) {
                AppVisibility.toggle()
            }
            KeyboardShortcuts.onKeyUp(for: .refreshPullRequests) {
                Task { @MainActor in
                    await monitor.refreshNow()
                }
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

    @MainActor
    private static func makeMonitor() -> PRMonitor {
        #if DEBUG
        if ProcessInfo.processInfo.usesMockGitHubPRs {
            return PRMonitor(api: MockGitHubAPI(),
                             tokenStore: MockTokenStore(),
                             isUsingMockData: true)
        }
        #endif

        return PRMonitor()
    }
}

private extension ProcessInfo {
    var isRunningTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    #if DEBUG
    var usesMockGitHubPRs: Bool {
        arguments.contains("--mock-github-prs")
        || environment["GITHUB_PANEL_MOCK_PRS"] == "1"
        || UserDefaults.standard.bool(forKey: "GithubPanel.useMockGitHubPRs")
    }
    #endif
}

#if DEBUG
private final class MockTokenStore: TokenStoring {
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

private final class MockGitHubAPI: GitHubAPIClient {
    private let user = GitHubUser(login: "mock-user")
    private var pullRequests: [String: PullRequestInfo]
    private let summaries: [PullRequestSummary]

    init(now: Date = Date()) {
        let rows = Self.makePullRequests(now: now)
        self.pullRequests = Dictionary(uniqueKeysWithValues: rows.map { ("\($0.repoFullName)#\($0.number)", $0) })
        self.summaries = rows.map {
            PullRequestSummary(id: "\($0.repoFullName)#\($0.number)",
                               title: $0.title,
                               number: $0.number,
                               repoFullName: $0.repoFullName,
                               htmlURL: $0.htmlURL,
                               updatedAt: now.addingTimeInterval(TimeInterval(-$0.number * 70)))
        }
    }

    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        user
    }

    func fetchOpenPRs(token: String, username: String) async throws -> [PullRequestSummary] {
        summaries
    }

    func fetchPullRequest(token: String, repoFullName: String, number: Int) async throws -> PullRequestInfo {
        pullRequests["\(repoFullName)#\(number)"] ?? Self.pullRequest(number: number,
                                                                      title: "Mock PR \(number)",
                                                                      status: .unknown)
    }

    func fetchPRCheckState(token: String, pr: PullRequestInfo) async throws -> CheckState {
        pr.status
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

    private func updatePullRequest(with nodeID: String, transform: (PullRequestInfo) -> PullRequestInfo) {
        guard let match = pullRequests.first(where: { $0.value.nodeID == nodeID }) else { return }
        pullRequests[match.key] = transform(match.value)
    }

    private static func makePullRequests(now: Date) -> [PullRequestInfo] {
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

    private static func pullRequest(number: Int,
                                    title: String,
                                    status: CheckState,
                                    isDraft: Bool = false,
                                    isAutoMergeEnabled: Bool = false,
                                    canEnableAutoMerge: Bool = false,
                                    canDisableAutoMerge: Bool = false,
                                    isMergeQueueEnabled: Bool = false,
                                    isInMergeQueue: Bool = false,
                                    mergeStateStatus: String = "CLEAN") -> PullRequestInfo {
        PullRequestInfo(nodeID: "mock-node-\(number)",
                        title: title,
                        number: number,
                        repoFullName: "mock/github-panel",
                        htmlURL: URL(string: "https://github.com/mock/github-panel/pull/\(number)")!,
                        headSHA: "mock-sha-\(number)",
                        isDraft: isDraft,
                        status: status,
                        isAutoMergeEnabled: isAutoMergeEnabled,
                        canEnableAutoMerge: canEnableAutoMerge,
                        canDisableAutoMerge: canDisableAutoMerge,
                        isMergeQueueEnabled: isMergeQueueEnabled,
                        isInMergeQueue: isInMergeQueue,
                        mergeStateStatus: mergeStateStatus)
    }
}

private extension PullRequestInfo {
    func copy(isAutoMergeEnabled: Bool? = nil,
              canEnableAutoMerge: Bool? = nil,
              canDisableAutoMerge: Bool? = nil,
              isInMergeQueue: Bool? = nil,
              mergeStateStatus: String? = nil) -> PullRequestInfo {
        PullRequestInfo(nodeID: nodeID,
                        title: title,
                        number: number,
                        repoFullName: repoFullName,
                        htmlURL: htmlURL,
                        headSHA: headSHA,
                        isDraft: isDraft,
                        status: status,
                        isAutoMergeEnabled: isAutoMergeEnabled ?? self.isAutoMergeEnabled,
                        canEnableAutoMerge: canEnableAutoMerge ?? self.canEnableAutoMerge,
                        canDisableAutoMerge: canDisableAutoMerge ?? self.canDisableAutoMerge,
                        isMergeQueueEnabled: isMergeQueueEnabled,
                        isInMergeQueue: isInMergeQueue ?? self.isInMergeQueue,
                        mergeStateStatus: mergeStateStatus ?? self.mergeStateStatus)
    }
}
#endif
