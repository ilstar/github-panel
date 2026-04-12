import Foundation
import Combine

protocol DefaultsStoring {
    func double(forKey defaultName: String) -> Double
    func set(_ value: Double, forKey defaultName: String)
}

extension UserDefaults: DefaultsStoring {}

protocol DateProviding {
    var now: Date { get }
}

struct SystemDateProvider: DateProviding {
    var now: Date { Date() }
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
    @Published var isLoading: Bool = false
    @Published var hasToken: Bool = false
    @Published var lastError: String?
    @Published var lastRefreshAt: Date?
    @Published var refreshInterval: TimeInterval {
        didSet {
            defaults.set(refreshInterval, forKey: DefaultsKeys.refreshInterval)
            scheduleTimer()
        }
    }

    private let api: GitHubAPIClient
    private let tokenStore: TokenStoring
    private let notificationPoster: NotificationPosting
    private let defaults: DefaultsStoring
    private let timerScheduler: TimerScheduling
    private let dateProvider: DateProviding
    private var timer: RefreshTimer?
    private var lastStates: [String: CheckState] = [:]
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
         dateProvider: DateProviding = SystemDateProvider()) {
        self.api = api
        self.tokenStore = tokenStore
        self.notificationPoster = notificationPoster
        self.defaults = defaults
        self.timerScheduler = timerScheduler
        self.dateProvider = dateProvider
        let stored = defaults.double(forKey: DefaultsKeys.refreshInterval)
        if stored == 0 {
            refreshInterval = 60
        } else {
            refreshInterval = stored
        }
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
            }
            lastStates[pr.id] = pr.status
        }

        // Remove states for PRs that are no longer in the list.
        lastStates = lastStates.filter { seen.contains($0.key) }
    }

    func requestMerge(for row: PullRequestRow) async {
        guard let token = tokenStore.loadToken() else { return }
        do {
            if row.isInMergeQueue || row.status == .failure || row.status == .error {
                return
            }

            if row.status == .success && !row.isDraft {
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

private enum DefaultsKeys {
    static let refreshInterval = "GithubPanel.refreshInterval"
}
