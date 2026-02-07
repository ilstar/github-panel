import Foundation
import Combine

@MainActor
final class PRMonitor: ObservableObject {
    @Published var prRows: [PullRequestRow] = []
    @Published var isLoading: Bool = false
    @Published var hasToken: Bool = false
    @Published var lastError: String?

    private let api = GitHubAPI()
    private let tokenStore = KeychainStore()
    private var timer: Timer?
    private var lastState: CheckState?
    private var lastActiveID: String?

    func start() {
        hasToken = tokenStore.hasToken
        refresh()
        scheduleTimer()
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
        lastState = nil
        lastActiveID = nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
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
                updateActiveStatus()
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
                                          title: summary.title,
                                          number: summary.number,
                                          repoFullName: summary.repoFullName,
                                          htmlURL: summary.htmlURL,
                                          status: state)
                }
            }

            for try await row in group {
                rowsByID[row.id] = row
            }
        }

        return limited.compactMap { rowsByID[$0.id] }
    }

    private func updateActiveStatus() {
        guard let first = prRows.first else {
            lastState = nil
            lastActiveID = nil
            return
        }

        if lastActiveID != first.id {
            lastState = nil
            lastActiveID = first.id
        }

        if let previous = lastState,
           previous == .pending,
           first.status != .pending {
            NotificationManager.shared.postStatusNotification(state: first.status,
                                                              title: first.title,
                                                              repoFullName: first.repoFullName,
                                                              number: first.number,
                                                              htmlURL: first.htmlURL)
        }
        lastState = first.status
    }
}
