import Foundation
import Combine

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

    private let api = GitHubAPI()
    private let tokenStore = KeychainStore()
    private var timer: Timer?
    private var lastStates: [String: CheckState] = [:]
    private let defaults = UserDefaults.standard
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init() {
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
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let token = tokenStore.loadToken() else { return }
        isLoading = true
        lastError = nil
        Task {
            do {
                let user = try await api.fetchCurrentUser(token: token)
                let summaries = try await api.fetchOpenPRs(token: token, username: user.login)
                prRows = try await buildRows(token: token, summaries: summaries)
                updateNotificationsForRows()
                lastRefreshAt = Date()
            } catch {
                prRows = []
                lastError = error.localizedDescription
            }
            isLoading = false
        }
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
                    let state = try await self.api.fetchPRCheckState(token: token, pr: pr)
                    return PullRequestRow(id: summary.id,
                                          nodeID: pr.nodeID,
                                          title: summary.title,
                                          number: summary.number,
                                          repoFullName: summary.repoFullName,
                                          htmlURL: summary.htmlURL,
                                          status: state,
                                          isDraft: pr.isDraft,
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
                NotificationManager.shared.postStatusNotification(state: pr.status,
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
            if row.status == .success && !row.isDraft {
                do {
                    try await api.mergePullRequest(token: token, repoFullName: row.repoFullName, number: row.number)
                } catch {
                    try await fallbackQueueOrAutomerge(token: token, row: row, error: error)
                }
            } else {
                try await fallbackQueueOrAutomerge(token: token, row: row, error: nil)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fallbackQueueOrAutomerge(token: String, row: PullRequestRow, error: Error?) async throws {
        do {
            try await api.enableAutoMerge(token: token, pullRequestID: row.nodeID)
        } catch {
            try await api.enqueuePullRequest(token: token, pullRequestID: row.nodeID)
        }
    }
}

private enum DefaultsKeys {
    static let refreshInterval = "GithubPanel.refreshInterval"
}
