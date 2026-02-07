import Foundation
import Combine

@MainActor
final class PRMonitor: ObservableObject {
    @Published var activePR: PullRequestInfo?
    @Published var statusText: String = ""
    @Published var statusEmoji: String = ""
    @Published var isLoading: Bool = false
    @Published var hasToken: Bool = false
    @Published var lastError: String?

    private let api = GitHubAPI()
    private let tokenStore = KeychainStore()
    private var timer: Timer?
    private var lastState: CheckState?
    private var lastPRURL: URL?

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
        activePR = nil
        statusText = ""
        statusEmoji = ""
        lastState = nil
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
                if let pr = try await api.fetchLatestOpenPR(token: token, username: user.login) {
                    activePR = pr
                    let state = try await api.fetchPRCheckState(token: token, pr: pr)
                    updateStatus(state: state, pr: pr)
                } else {
                    activePR = nil
                    statusText = ""
                    statusEmoji = ""
                    lastState = nil
                    lastPRURL = nil
                }
            } catch {
                activePR = nil
                statusText = "Failed to load PR status."
                statusEmoji = "⚠️"
                lastError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func updateStatus(state: CheckState, pr: PullRequestInfo) {
        if lastPRURL != pr.htmlURL {
            lastState = nil
            lastPRURL = pr.htmlURL
        }
        statusText = state.descriptionText
        statusEmoji = state.emoji

        if let previous = lastState,
           previous == .pending,
           state != .pending {
            NotificationManager.shared.postStatusNotification(state: state, pr: pr)
        }
        lastState = state
    }
}
