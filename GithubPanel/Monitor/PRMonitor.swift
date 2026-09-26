import Foundation
import Combine
@MainActor
final class PRMonitor: ObservableObject {
    @Published var prRows: [PullRequestRow] = []
    @Published var historyRows: [PullRequestHistoryRow] = []
    @Published var reviewRequests: ReviewRequests = .empty
    @Published var selectedTab: PullRequestTab = .open
    @Published var isLoading: Bool = false
    @Published var isHistoryLoading: Bool = false
    @Published var isReviewRequestsLoading: Bool = false
    @Published var hasToken: Bool = false
    @Published var lastError: String?
    @Published var lastHistoryError: String?
    @Published var lastReviewRequestsError: String?
    @Published var lastRefreshAt: Date?
    @Published var lastHistoryRefreshAt: Date?
    @Published var lastReviewRequestsRefreshAt: Date?
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
    private var credentialSession = UUID()
    private var didLoadSessionToken = false
    private var sessionToken: String?
    private var cachedLogin: String?
    private var timer: RefreshTimer?
    private var activeRefreshTask: Task<Void, Never>?
    private var activeRefreshID: UUID?
    private var refreshQueued = false
    private var refreshRevision = 0
    private var historyLoadedSuccessfully = false
    private var lastStates: [String: CheckState] = [:]
    private var nextTimerRefreshAt: Date?
    private var consecutiveThrottledFailures = 0
    private let maxThrottledBackoff: TimeInterval = 30 * 60
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
        hasToken = loadSessionToken() != nil
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
        invalidateLogin()
        tokenStore.saveToken(token)
        sessionToken = token
        didLoadSessionToken = true
        hasToken = true
        refresh()
    }

    func clearToken() {
        invalidateLogin()
        tokenStore.clearToken()
        sessionToken = nil
        didLoadSessionToken = true
        hasToken = false
        setPRRows([])
        setHistoryRows([])
        setReviewRequests(.empty)
        historyPage = 1
        historyTotalCount = 0
        lastStates = [:]
    }

    private func invalidateLogin() {
        credentialSession = UUID()
        cachedLogin = nil
        activeRefreshTask?.cancel()
        activeRefreshTask = nil
        activeRefreshID = nil
        refreshQueued = false
        historyLoadedSuccessfully = false
        nextTimerRefreshAt = nil
        consecutiveThrottledFailures = 0
        isLoading = false
        isHistoryLoading = false
        isReviewRequestsLoading = false
    }

    func scheduleTimer() {
        timer?.invalidate()
        timer = timerScheduler.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] in
            Task { await self?.handleTimerTick() }
        }
    }

    /// Timer-driven refresh. Skips the fetch when another refresh finished recently
    /// or while backing off from auth/rate-limit failures.
    func handleTimerTick() async {
        if let nextTimerRefreshAt, dateProvider.now < nextTimerRefreshAt {
            return
        }
        await refreshNow()
    }

    private func refresh() {
        Task {
            await refreshNow()
        }
    }

    private func loadSessionToken() -> String? {
        guard !didLoadSessionToken else { return sessionToken }
        sessionToken = tokenStore.loadToken()
        didLoadSessionToken = true
        return sessionToken
    }

    func refreshNow() async {
        guard loadSessionToken() != nil else { return }
        let task = startRefreshIfNeeded()
        await task.value
    }

    func loadHistoryIfNeeded() {
        Task {
            await refreshHistory(page: historyPage, onlyIfNeeded: true)
        }
    }

    func refreshCurrentHistoryPage() async {
        await refreshHistory(page: historyPage, onlyIfNeeded: false)
    }

    func loadNextHistoryPage() async {
        guard canLoadNextHistoryPage else { return }
        await refreshHistory(page: historyPage + 1, onlyIfNeeded: false)
    }

    func loadPreviousHistoryPage() async {
        guard canLoadPreviousHistoryPage else { return }
        await refreshHistory(page: historyPage - 1, onlyIfNeeded: false)
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

    private func refreshHistory(page: Int, onlyIfNeeded: Bool) async {
        guard let token = loadSessionToken() else { return }
        guard !isHistoryLoading else { return }
        guard !onlyIfNeeded || !historyLoadedSuccessfully else { return }
        let session = credentialSession
        isHistoryLoading = true
        lastHistoryError = nil
        do {
            let login: String
            if let cachedLogin {
                login = cachedLogin
            } else {
                login = try await api.fetchCurrentUser(token: token).login
                guard session == credentialSession else { return }
                cachedLogin = login
            }
            let page = try await api.fetchClosedPRs(token: token,
                                                    username: login,
                                                    page: page,
                                                    perPage: historyPageSize)
            guard session == credentialSession else { return }
            setHistoryRows(page.rows)
            historyPage = page.page
            historyTotalCount = page.totalCount
            historyLoadedSuccessfully = true
            lastHistoryRefreshAt = dateProvider.now
        } catch {
            guard session == credentialSession else { return }
            setHistoryRows([])
            historyTotalCount = 0
            historyLoadedSuccessfully = false
            lastHistoryError = error.localizedDescription
        }
        isHistoryLoading = false
    }

    func refreshReviewRequests() async {
        guard let token = loadSessionToken() else { return }
        guard !isReviewRequestsLoading else { return }
        let session = credentialSession
        isReviewRequestsLoading = true
        lastReviewRequestsError = nil
        do {
            let requests = try await api.fetchReviewRequests(token: token)
            guard session == credentialSession else { return }
            setReviewRequests(requests)
            lastReviewRequestsRefreshAt = dateProvider.now
        } catch {
            guard session == credentialSession else { return }
            setReviewRequests(.empty)
            lastReviewRequestsError = error.localizedDescription
        }
        isReviewRequestsLoading = false
    }

    private func startRefreshIfNeeded() -> Task<Void, Never> {
        if let activeRefreshTask {
            return activeRefreshTask
        }

        let session = credentialSession
        let refreshID = UUID()
        isLoading = true
        lastError = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRefresh(session: session, refreshID: refreshID)
        }
        activeRefreshTask = task
        activeRefreshID = refreshID
        return task
    }

    private func runRefresh(session: UUID, refreshID: UUID) async {
        while true {
            guard let token = loadSessionToken() else { break }
            let requestRevision = refreshRevision

            do {
                let result = try await api.fetchOpenPRs(token: token)
                guard session == credentialSession else { return }
                scheduleNextTimerRefresh(after: nil)
                if requestRevision == refreshRevision {
                    cachedLogin = result.login
                    updateNotificationsForRows(result.rows)
                    setPRRows(result.rows)
                    lastRefreshAt = dateProvider.now
                }
            } catch {
                guard session == credentialSession else { return }
                scheduleNextTimerRefresh(after: error)
                if requestRevision == refreshRevision {
                    setPRRows([])
                    lastError = error.localizedDescription
                }
            }

            guard session == credentialSession else { return }
            guard refreshQueued else { break }
            refreshQueued = false
        }

        guard session == credentialSession, activeRefreshID == refreshID else { return }
        activeRefreshTask = nil
        activeRefreshID = nil
        isLoading = false
    }

    private func scheduleNextTimerRefresh(after error: Error?) {
        let delay: TimeInterval
        if let error, Self.isThrottlingError(error) {
            consecutiveThrottledFailures += 1
            let backoff = refreshInterval * pow(2, Double(consecutiveThrottledFailures))
            delay = min(backoff, max(refreshInterval, maxThrottledBackoff))
        } else {
            consecutiveThrottledFailures = 0
            delay = refreshInterval
        }
        // Ticks run on a fixed cadence that started before this fetch completed, so allow
        // half an interval of slack; otherwise the tick due after `delay` would be skipped.
        nextTimerRefreshAt = dateProvider.now.addingTimeInterval(delay - refreshInterval / 2)
    }

    private static func isThrottlingError(_ error: Error) -> Bool {
        let statusCode = (error as? GraphQLError)?.statusCode ?? (error as? GitHubAPIError)?.statusCode
        guard let statusCode else { return false }
        return [401, 403, 429].contains(statusCode)
    }

    private func requireFreshRefresh(for session: UUID) async {
        guard session == credentialSession else { return }
        refreshRevision += 1
        if activeRefreshTask != nil {
            refreshQueued = true
        }
        await refreshNow()
    }

    private func setPRRows(_ rows: [PullRequestRow]) {
        guard prRows != rows else { return }
        prRows = rows
    }

    private func setHistoryRows(_ rows: [PullRequestHistoryRow]) {
        guard historyRows != rows else { return }
        historyRows = rows
    }

    private func setReviewRequests(_ requests: ReviewRequests) {
        guard reviewRequests != requests else { return }
        reviewRequests = requests
    }

    private func updateNotificationsForRows(_ rows: [PullRequestRow]) {
        var seen: Set<String> = []

        for pr in rows {
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
        case .noChecks:
            return nil
        case .failure, .error:
            return .anyFailures
        case .pending, .unknown:
            return nil
        }
    }

    func fetchPullRequestDetail(_ reference: PullRequestReference) async throws -> PullRequestDetailContent {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        return try await api.fetchPullRequestDetail(token: token, reference: reference)
    }

    func requestMarkReady(for row: PullRequestRow) async {
        guard row.isDraft, let token = loadSessionToken() else { return }
        let session = credentialSession
        do {
            try await api.markPullRequestReadyForReview(token: token, pullRequestID: row.nodeID)
            await requireFreshRefresh(for: session)
        } catch {
            guard session == credentialSession else { return }
            lastError = error.localizedDescription
        }
    }

    func requestMerge(for row: PullRequestRow) async {
        guard !row.isDraft, let token = loadSessionToken() else { return }
        let session = credentialSession
        do {
            // Use the same resolver as the row's button so the label and the action cannot drift apart.
            switch MergeButtonState.resolve(for: row, isWorking: false) {
            case .enqueue:
                try await api.enqueuePullRequest(token: token, pullRequestID: row.nodeID)
                await requireFreshRefresh(for: session)
            case .merge:
                let merged = try await api.mergePullRequest(token: token, repoFullName: row.repoFullName, number: row.number)
                guard session == credentialSession else { return }
                if merged {
                    setPRRows(prRows.filter { $0.id != row.id })
                    lastStates.removeValue(forKey: row.id)
                    await requireFreshRefresh(for: session)
                }
            case .disableAutoMerge:
                guard row.canDisableAutoMerge else { return }
                try await api.disableAutoMerge(token: token, pullRequestID: row.nodeID)
                await requireFreshRefresh(for: session)
            case .enableAutoMerge:
                try await api.enableAutoMerge(token: token, pullRequestID: row.nodeID)
                await requireFreshRefresh(for: session)
            case .markReady, .queued, .checksFailed, .blocked, .statusUnavailable, .waitingForChecks, .working:
                return
            }
        } catch {
            guard session == credentialSession else { return }
            lastError = error.localizedDescription
        }
    }
}

struct MissingTokenError: LocalizedError {
    var errorDescription: String? { "Add a GitHub token to load pull requests." }
}

private enum DefaultsKeys {
    static let refreshInterval = "GithubPanel.refreshInterval"
    static let allSucceededHookScript = "GithubPanel.hooks.allSucceededScript"
    static let anyFailuresHookScript = "GithubPanel.hooks.anyFailuresScript"
}
