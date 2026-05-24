import Foundation
import Combine

protocol DefaultsStoring {
    func double(forKey defaultName: String) -> Double
    func string(forKey defaultName: String) -> String?
    func set(_ value: Double, forKey defaultName: String)
    func set(_ value: String, forKey defaultName: String)
}

extension UserDefaults: DefaultsStoring {
    func set(_ value: String, forKey defaultName: String) {
        set(value as Any, forKey: defaultName)
    }
}

protocol DateProviding {
    var now: Date { get }
}

struct SystemDateProvider: DateProviding {
    var now: Date { Date() }
}

enum PullRequestHookScenario: String {
    case anyFailures = "any_failures"
    case allSucceeded = "all_succeeded"
}

struct PullRequestHookContext {
    let scenario: PullRequestHookScenario
    let status: CheckState
    let id: String
    let nodeID: String
    let number: Int
    let title: String
    let repoFullName: String
    let htmlURL: URL
    let headSHA: String

    var environment: [String: String] {
        let repoParts = repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        var values = [
            "GITHUB_PANEL_HOOK_SCENARIO": scenario.rawValue,
            "GITHUB_PANEL_PR_STATUS": status.rawValue,
            "GITHUB_PANEL_PR_ID": id,
            "GITHUB_PANEL_PR_NODE_ID": nodeID,
            "GITHUB_PANEL_PR_NUMBER": String(number),
            "GITHUB_PANEL_PR_TITLE": title,
            "GITHUB_PANEL_REPO_FULL_NAME": repoFullName,
            "GITHUB_PANEL_PR_URL": htmlURL.absoluteString,
            "GITHUB_PANEL_PR_HEAD_SHA": headSHA
        ]
        if repoParts.count == 2 {
            values["GITHUB_PANEL_REPO_OWNER"] = repoParts[0]
            values["GITHUB_PANEL_REPO_NAME"] = repoParts[1]
        }
        return values
    }
}

protocol PullRequestHookRunning {
    func run(script: String, context: PullRequestHookContext)
}

struct SystemPullRequestHookRunner: PullRequestHookRunning {
    func run(script: String, context: PullRequestHookContext) {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", trimmed]
            var environment = ProcessInfo.processInfo.environment
            context.environment.forEach { environment[$0.key] = $0.value }
            process.environment = environment

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                NSLog("GithubPanel hook failed to start: \(error.localizedDescription)")
            }
        }
    }
}

protocol RefreshTimer {
    func invalidate()
}

extension Timer: RefreshTimer {}

protocol TimerScheduling {
    func scheduledTimer(withTimeInterval interval: TimeInterval,
                        repeats: Bool,
                        block: @escaping @MainActor () -> Void) -> RefreshTimer
}

struct SystemTimerScheduler: TimerScheduling {
    func scheduledTimer(withTimeInterval interval: TimeInterval,
                        repeats: Bool,
                        block: @escaping @MainActor () -> Void) -> RefreshTimer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            Task { @MainActor in
                block()
            }
        }
    }
}

@MainActor
final class PRMonitor: ObservableObject {
    @Published var prRows: [PullRequestRow] = []
    @Published var historyRows: [PullRequestHistoryRow] = []
    @Published var selectedTab: PullRequestTab = .open
    @Published var isLoading: Bool = false
    @Published var isHistoryLoading: Bool = false
    @Published var hasToken: Bool = false
    @Published var lastError: String?
    @Published var lastHistoryError: String?
    @Published var lastRefreshAt: Date?
    @Published var lastHistoryRefreshAt: Date?
    @Published var historyPage: Int = 1
    @Published var historyTotalCount: Int = 0
    let isUsingMockData: Bool
    @Published var refreshInterval: TimeInterval {
        didSet {
            defaults.set(refreshInterval, forKey: DefaultsKeys.refreshInterval)
            scheduleTimer()
        }
    }
    @Published var allSucceededHookScript: String {
        didSet {
            defaults.set(allSucceededHookScript, forKey: DefaultsKeys.allSucceededHookScript)
        }
    }
    @Published var anyFailuresHookScript: String {
        didSet {
            defaults.set(anyFailuresHookScript, forKey: DefaultsKeys.anyFailuresHookScript)
        }
    }

    private let api: GitHubAPIClient
    private let tokenStore: TokenStoring
    private let notificationPoster: NotificationPosting
    private let defaults: DefaultsStoring
    private let timerScheduler: TimerScheduling
    private let dateProvider: DateProviding
    private let hookRunner: PullRequestHookRunning
    private var timer: RefreshTimer?
    private var lastStates: [String: CheckState] = [:]
    private let historyPageSize = 10
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(api: GitHubAPIClient = GitHubAPI(),
         tokenStore: TokenStoring = KeychainStore(),
         notificationPoster: NotificationPosting = NotificationManager.shared,
         defaults: DefaultsStoring = UserDefaults.standard,
         timerScheduler: TimerScheduling = SystemTimerScheduler(),
         dateProvider: DateProviding = SystemDateProvider(),
         hookRunner: PullRequestHookRunning = SystemPullRequestHookRunner(),
         isUsingMockData: Bool = false) {
        self.api = api
        self.tokenStore = tokenStore
        self.notificationPoster = notificationPoster
        self.defaults = defaults
        self.timerScheduler = timerScheduler
        self.dateProvider = dateProvider
        self.hookRunner = hookRunner
        self.isUsingMockData = isUsingMockData
        let stored = defaults.double(forKey: DefaultsKeys.refreshInterval)
        if stored == 0 {
            refreshInterval = 60
        } else {
            refreshInterval = stored
        }
        allSucceededHookScript = defaults.string(forKey: DefaultsKeys.allSucceededHookScript) ?? ""
        anyFailuresHookScript = defaults.string(forKey: DefaultsKeys.anyFailuresHookScript) ?? ""
    }

    func start() {
        hasToken = tokenStore.hasToken
        refresh()
        scheduleTimer()
    }

    func lastRefreshText(relativeTo now: Date) -> String {
        guard let lastRefreshAt else {
            return "Never"
        }
        return relativeFormatter.localizedString(for: lastRefreshAt, relativeTo: now)
    }

    func saveToken(_ token: String) {
        tokenStore.saveToken(token)
        hasToken = true
        refresh()
    }

    func clearToken() {
        tokenStore.clearToken()
        hasToken = false
        prRows = []
        historyRows = []
        historyPage = 1
        historyTotalCount = 0
        lastStates = [:]
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = timerScheduler.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        Task {
            await refreshNow()
        }
    }

    func refreshNow() async {
        guard let token = tokenStore.loadToken() else { return }
        isLoading = true
        lastError = nil
        do {
            let user = try await api.fetchCurrentUser(token: token)
            let summaries = try await api.fetchOpenPRs(token: token, username: user.login)
            prRows = try await buildRows(token: token, summaries: summaries)
            updateNotificationsForRows()
            lastRefreshAt = dateProvider.now
        } catch {
            prRows = []
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    func loadHistoryIfNeeded() {
        guard historyRows.isEmpty, !isHistoryLoading else { return }
        Task {
            await refreshHistory(page: historyPage)
        }
    }

    func refreshCurrentHistoryPage() async {
        await refreshHistory(page: historyPage)
    }

    func loadNextHistoryPage() async {
        guard canLoadNextHistoryPage else { return }
        await refreshHistory(page: historyPage + 1)
    }

    func loadPreviousHistoryPage() async {
        guard canLoadPreviousHistoryPage else { return }
        await refreshHistory(page: historyPage - 1)
    }

    var canLoadPreviousHistoryPage: Bool {
        historyPage > 1 && !isHistoryLoading
    }

    var canLoadNextHistoryPage: Bool {
        historyPage * historyPageSize < historyTotalCount && !isHistoryLoading
    }

    var historyRangeText: String {
        guard !historyRows.isEmpty else {
            return historyTotalCount == 0 ? "No history" : "Page \(historyPage)"
        }
        let start = ((historyPage - 1) * historyPageSize) + 1
        let end = start + historyRows.count - 1
        return "\(start)-\(end) of \(historyTotalCount)"
    }

    private func refreshHistory(page: Int) async {
        guard let token = tokenStore.loadToken() else { return }
        isHistoryLoading = true
        lastHistoryError = nil
        do {
            let user = try await api.fetchCurrentUser(token: token)
            let page = try await api.fetchClosedPRs(token: token,
                                                    username: user.login,
                                                    page: page,
                                                    perPage: historyPageSize)
            historyRows = page.rows
            historyPage = page.page
            historyTotalCount = page.totalCount
            lastHistoryRefreshAt = dateProvider.now
        } catch {
            historyRows = []
            historyTotalCount = 0
            lastHistoryError = error.localizedDescription
        }
        isHistoryLoading = false
    }

    private func buildRows(token: String, summaries: [PullRequestSummary]) async throws -> [PullRequestRow] {
        let limited = Array(summaries.prefix(10))
        var rowsByID: [String: PullRequestRow] = [:]

        try await withThrowingTaskGroup(of: PullRequestRow.self) { group in
            for summary in limited {
                group.addTask {
                    let pr = try await self.api.fetchPullRequest(token: token,
                                                                 repoFullName: summary.repoFullName,
                                                                 number: summary.number)
                    return PullRequestRow(id: summary.id,
                                          nodeID: pr.nodeID,
                                          title: summary.title,
                                          number: summary.number,
                                          repoFullName: summary.repoFullName,
                                          htmlURL: summary.htmlURL,
                                          headSHA: pr.headSHA,
                                          status: pr.status,
                                          isDraft: pr.isDraft,
                                          isAutoMergeEnabled: pr.isAutoMergeEnabled,
                                          canEnableAutoMerge: pr.canEnableAutoMerge,
                                          canDisableAutoMerge: pr.canDisableAutoMerge,
                                          isMergeQueueEnabled: pr.isMergeQueueEnabled,
                                          isInMergeQueue: pr.isInMergeQueue,
                                          mergeStateStatus: pr.mergeStateStatus,
                                          updatedAt: summary.updatedAt)
                }
            }

            for try await row in group {
                rowsByID[row.id] = row
            }
        }

        return limited.compactMap { rowsByID[$0.id] }
    }

    private func updateNotificationsForRows() {
        var seen: Set<String> = []

        for pr in prRows {
            seen.insert(pr.id)
            if let previous = lastStates[pr.id],
               previous == .pending,
               pr.status != .pending {
                notificationPoster.postStatusNotification(state: pr.status,
                                                          title: pr.title,
                                                          repoFullName: pr.repoFullName,
                                                          number: pr.number,
                                                          htmlURL: pr.htmlURL)
                runHookIfConfigured(for: pr)
            }
            lastStates[pr.id] = pr.status
        }

        // Remove states for PRs that are no longer in the list.
        lastStates = lastStates.filter { seen.contains($0.key) }
    }

    private func runHookIfConfigured(for pr: PullRequestRow) {
        guard let scenario = hookScenario(for: pr.status) else { return }
        let script: String
        switch scenario {
        case .anyFailures:
            script = anyFailuresHookScript
        case .allSucceeded:
            script = allSucceededHookScript
        }
        let context = PullRequestHookContext(scenario: scenario,
                                             status: pr.status,
                                             id: pr.id,
                                             nodeID: pr.nodeID,
                                             number: pr.number,
                                             title: pr.title,
                                             repoFullName: pr.repoFullName,
                                             htmlURL: pr.htmlURL,
                                             headSHA: pr.headSHA)
        hookRunner.run(script: script, context: context)
    }

    private func hookScenario(for state: CheckState) -> PullRequestHookScenario? {
        switch state {
        case .success:
            return .allSucceeded
        case .failure, .error:
            return .anyFailures
        case .pending, .unknown:
            return nil
        }
    }

    func requestMerge(for row: PullRequestRow) async {
        guard let token = tokenStore.loadToken() else { return }
        do {
            if row.isInMergeQueue || row.status == .failure || row.status == .error {
                return
            }

            if row.canMergeImmediately {
                if row.isMergeQueueEnabled {
                    try await api.enqueuePullRequest(token: token, pullRequestID: row.nodeID)
                    await refreshNow()
                    return
                }

                let merged = try await api.mergePullRequest(token: token, repoFullName: row.repoFullName, number: row.number)
                if merged {
                    prRows.removeAll { $0.id == row.id }
                    lastStates.removeValue(forKey: row.id)
                }
                return
            }

            if row.isAutoMergeEnabled {
                guard row.canDisableAutoMerge else { return }
                try await api.disableAutoMerge(token: token, pullRequestID: row.nodeID)
                await refreshNow()
                return
            }

            guard row.canEnableAutoMerge else { return }
            try await api.enableAutoMerge(token: token, pullRequestID: row.nodeID)
            await refreshNow()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

enum PullRequestTab: String, CaseIterable, Identifiable {
    case open
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "Open"
        case .history: return "History"
        }
    }
}

private enum DefaultsKeys {
    static let refreshInterval = "GithubPanel.refreshInterval"
    static let allSucceededHookScript = "GithubPanel.hooks.allSucceededScript"
    static let anyFailuresHookScript = "GithubPanel.hooks.anyFailuresScript"
}
