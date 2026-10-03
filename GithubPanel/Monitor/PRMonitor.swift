import Foundation
import Combine
@MainActor
final class PRMonitor: ObservableObject {
    @Published var prRows: [PullRequestRow] = []
    @Published var historyRows: [PullRequestHistoryRow] = []
    @Published var reviewRequests: ReviewRequests = .empty
    @Published var selectedTab: PullRequestTab = .open {
        didSet {
            guard selectedTab != oldValue else { return }
            loadSelectedTab()
        }
    }
    @Published var isLoading: Bool = false
    @Published var isHistoryLoading: Bool = false
    @Published var isReviewRequestsLoading: Bool = false
    @Published var hasToken: Bool = false
    @Published var lastError: String?
    @Published var lastHistoryError: String?
    @Published var lastReviewRequestsError: String?
    /// Set when the last open pull request refresh left some out because the token isn't SSO-authorized.
    @Published var openPullRequestsSSOAuthorizationURL: URL?
    @Published var lastRefreshAt: Date?
    @Published var lastHistoryRefreshAt: Date?
    @Published var lastReviewRequestsRefreshAt: Date?
    @Published var historyPage: Int = 1
    @Published var historyTotalCount: Int = 0
    let isUsingMockData: Bool
    /// A pull request a clicked notification asked to show. The main window selects it, then clears this.
    @Published var pullRequestToShow: PullRequestToShow?
    /// Details and comments of pull requests loaded so far, shared by every detail view.
    let detailCache = PullRequestDetailCache()
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

    @Published var notifyCheckResults: Bool {
        didSet { defaults.set(notifyCheckResults, forKey: DefaultsKeys.notifyCheckResults) }
    }
    @Published var notifyApprovals: Bool {
        didSet { defaults.set(notifyApprovals, forKey: DefaultsKeys.notifyApprovals) }
    }
    @Published var notifyChangesRequested: Bool {
        didSet { defaults.set(notifyChangesRequested, forKey: DefaultsKeys.notifyChangesRequested) }
    }
    @Published var notifyReviewsFromMe: Bool {
        didSet { defaults.set(notifyReviewsFromMe, forKey: DefaultsKeys.notifyReviewsFromMe) }
    }
    @Published var notifyReviewsFromMyTeams: Bool {
        didSet { defaults.set(notifyReviewsFromMyTeams, forKey: DefaultsKeys.notifyReviewsFromMyTeams) }
    }

    /// Merge methods picked from a row's menu, keyed by repository. Also saved to defaults.
    @Published private var mergeMethodChoices: [String: MergeMethod] = [:]

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
    private var prefetchTask: Task<Void, Never>?
    private var lastStates: [String: CheckState] = [:]
    private var lastReviewStatuses: [String: PullRequestReviewStatus] = [:]
    /// Review requests seen since the token was set. Nil until the first load, so the first list posts nothing.
    private var knownReviewRequestIDs: [ReviewRequestGroup: Set<String>]?
    /// Main windows showing the list. A clicked notification opens GitHub while there are none.
    private var listWindowCount = 0
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
         defaults: DefaultsStoring = AppDefaults.store,
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
        notifyCheckResults = defaults.object(forKey: DefaultsKeys.notifyCheckResults) as? Bool ?? true
        notifyApprovals = defaults.object(forKey: DefaultsKeys.notifyApprovals) as? Bool ?? true
        notifyChangesRequested = defaults.object(forKey: DefaultsKeys.notifyChangesRequested) as? Bool ?? true
        notifyReviewsFromMe = defaults.object(forKey: DefaultsKeys.notifyReviewsFromMe) as? Bool ?? true
        notifyReviewsFromMyTeams = defaults.object(forKey: DefaultsKeys.notifyReviewsFromMyTeams) as? Bool ?? true
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
        openPullRequestsSSOAuthorizationURL = nil
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
        nextTimerRefreshAt = nil
        consecutiveThrottledFailures = 0
        prefetchTask?.cancel()
        prefetchTask = nil
        lastReviewStatuses = [:]
        knownReviewRequestIDs = nil
        detailCache.removeAll()
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

    /// Refreshes My PRs and To Review together. App start, timer ticks and manual refresh on
    /// either tab all come through here, so switching between the two tabs never fetches.
    func refreshNow() async {
        guard loadSessionToken() != nil else { return }
        async let reviewRequests: Void = refreshReviewRequests()
        await refreshOpenPullRequests()
        await reviewRequests
    }

    private func refreshOpenPullRequests() async {
        guard loadSessionToken() != nil else { return }
        let task = startRefreshIfNeeded()
        await task.value
    }

    var isSelectedTabLoading: Bool {
        switch selectedTab {
        case .open: return isLoading
        case .reviews: return isReviewRequestsLoading
        case .history: return isHistoryLoading
        }
    }

    func refreshSelectedTab() async {
        switch selectedTab {
        case .open, .reviews: await refreshNow()
        case .history: await refreshCurrentHistoryPage()
        }
    }

    /// My PRs and To Review stay fresh through `refreshNow()`. History is rarely used, so the
    /// timer skips it and it reloads only when its tab is shown or refreshed by hand.
    private func loadSelectedTab() {
        guard selectedTab == .history else { return }
        Task { await refreshCurrentHistoryPage() }
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
        guard let token = loadSessionToken() else { return }
        guard !isHistoryLoading else { return }
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
            lastHistoryRefreshAt = dateProvider.now
        } catch {
            guard session == credentialSession else { return }
            setHistoryRows([])
            historyTotalCount = 0
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
            notifyAboutNewReviewRequests(requests)
            setReviewRequests(requests)
            lastReviewRequestsRefreshAt = dateProvider.now
        } catch {
            guard session == credentialSession else { return }
            // Keep the last list on screen; the error shows above it until a refresh succeeds.
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
                    openPullRequestsSSOAuthorizationURL = result.ssoAuthorizationURL
                    lastRefreshAt = dateProvider.now
                    prefetchDetails(for: result.rows)
                }
            } catch {
                guard session == credentialSession else { return }
                scheduleNextTimerRefresh(after: error)
                if requestRevision == refreshRevision {
                    // Keep the last list on screen; the error shows above it until a refresh succeeds.
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

    /// Loads, one pull request at a time, the details of open pull requests that changed since they were cached,
    /// so they show right away when opened. Unchanged pull requests cost no requests.
    private func prefetchDetails(for rows: [PullRequestRow]) {
        guard prefetchTask == nil, let token = loadSessionToken() else { return }
        let references = rows.filter { detailCache.needsRefresh($0.reference, updatedAt: $0.updatedAt) }.map(\.reference)
        guard !references.isEmpty else { return }
        let session = credentialSession
        prefetchTask = Task { @MainActor [weak self] in
            await self?.prefetch(references, token: token, session: session)
        }
    }

    private func prefetch(_ references: [PullRequestReference], token: String, session: UUID) async {
        defer {
            if session == credentialSession {
                prefetchTask = nil
            }
        }
        for reference in references {
            guard !Task.isCancelled, session == credentialSession else { return }
            do {
                async let comments = api.fetchPullRequestComments(token: token, reference: reference)
                let content = try await api.fetchPullRequestDetail(token: token, reference: reference)
                let loadedComments = try await comments
                guard session == credentialSession else { return }
                detailCache.store(content)
                detailCache.store(loadedComments, for: reference)
            } catch {
                // Prefetching is best effort. Stop when GitHub throttles, so the list refresh keeps its budget.
                if Self.isThrottlingError(error) { return }
            }
        }
    }

    /// Waits for the background detail prefetch to finish. Used by tests.
    func waitForPrefetch() async {
        await prefetchTask?.value
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
        await refreshOpenPullRequests()
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
                if notifyCheckResults {
                    notificationPoster.postStatusNotification(state: pr.status,
                                                              title: pr.title,
                                                              repoFullName: pr.repoFullName,
                                                              number: pr.number,
                                                              htmlURL: pr.htmlURL)
                }
                runHookIfConfigured(for: pr)
            }
            lastStates[pr.id] = pr.status
            if let previous = lastReviewStatuses[pr.id] {
                notifyAboutNewReviews(on: pr, previous: previous)
            }
            lastReviewStatuses[pr.id] = pr.reviewStatus
        }

        // Remove states for PRs that are no longer in the list.
        lastStates = lastStates.filter { seen.contains($0.key) }
        lastReviewStatuses = lastReviewStatuses.filter { seen.contains($0.key) }
    }

    /// Posts one notification for reviewers who approved since the last refresh, and one for those who asked for changes.
    private func notifyAboutNewReviews(on pr: PullRequestRow, previous: PullRequestReviewStatus) {
        let approvers = pr.reviewStatus.approvedBy.filter { !previous.approvedBy.contains($0) }
        let requesters = pr.reviewStatus.changesRequestedBy.filter { !previous.changesRequestedBy.contains($0) }
        if notifyApprovals && !approvers.isEmpty {
            notificationPoster.postPullRequestNotification(
                PullRequestNotification(kind: .approved(by: approvers), reference: pr.reference,
                                        pullRequestTitle: pr.title, htmlURL: pr.htmlURL))
        }
        if notifyChangesRequested && !requesters.isEmpty {
            notificationPoster.postPullRequestNotification(
                PullRequestNotification(kind: .changesRequested(by: requesters), reference: pr.reference,
                                        pullRequestTitle: pr.title, htmlURL: pr.htmlURL))
        }
    }

    /// Posts a notification for each ready pull request that asks for my review since the last refresh.
    private func notifyAboutNewReviewRequests(_ requests: ReviewRequests) {
        defer {
            knownReviewRequestIDs = Dictionary(uniqueKeysWithValues: ReviewRequestGroup.allCases.map {
                ($0, Set(requests.rows(in: $0).map(\.id)))
            })
        }
        guard let known = knownReviewRequestIDs else { return }
        var posted: Set<String> = []
        for group in ReviewRequestGroup.allCases {
            let enabled = group == .fromMe ? notifyReviewsFromMe : notifyReviewsFromMyTeams
            guard enabled else { continue }
            for row in requests.rows(in: group)
                where !(known[group] ?? []).contains(row.id) && !row.isDraft && posted.insert(row.id).inserted {
                notificationPoster.postPullRequestNotification(
                    PullRequestNotification(kind: .reviewRequested(by: row.authorLogin), reference: row.reference,
                                            pullRequestTitle: row.title, htmlURL: row.htmlURL))
            }
        }
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

    func fetchChangedFiles(in repoFullName: String, from baseSHA: String, to headSHA: String) async throws -> [PullRequestFile] {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        return try await api.fetchChangedFiles(token: token, repoFullName: repoFullName, baseSHA: baseSHA, headSHA: headSHA)
    }

    func setFileViewed(pullRequestID: String, path: String, viewed: Bool) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        try await api.setFileViewed(token: token, pullRequestID: pullRequestID, path: path, viewed: viewed)
    }

    func fetchPullRequestComments(_ reference: PullRequestReference) async throws -> PullRequestComments {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        return try await api.fetchPullRequestComments(token: token, reference: reference)
    }

    func postPullRequestComment(_ comment: NewPullRequestComment, on reference: PullRequestReference) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        try await api.postPullRequestComment(token: token, reference: reference, comment: comment)
    }

    func setReviewThreadResolved(threadID: String, resolved: Bool) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        try await api.setReviewThreadResolved(token: token, threadID: threadID, resolved: resolved)
    }

    /// Saves a new title, description, or both, then refreshes the list so the row shows the new title.
    func editPullRequest(_ reference: PullRequestReference, title: String?, body: String?) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        let session = credentialSession
        try await api.editPullRequest(token: token, reference: reference, title: title, body: body)
        await requireFreshRefresh(for: session)
    }

    /// Merges the base branch into the pull request's branch, then refreshes the list, whose merge state changes.
    func updatePullRequestBranch(pullRequestID: String, expectedHeadSHA: String) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        let session = credentialSession
        try await api.updatePullRequestBranch(token: token, pullRequestID: pullRequestID, expectedHeadSHA: expectedHeadSHA)
        await requireFreshRefresh(for: session)
    }

    func fetchReviewerCandidates(_ reference: PullRequestReference, query: String) async throws -> [ReviewerCandidate] {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        return try await api.fetchReviewerCandidates(token: token, reference: reference, query: query)
    }

    /// Requests a review, or removes a request, then refreshes the list, whose review tag can change.
    func setReviewRequested(_ name: String, kind: PullRequestReviewer.Kind, requested: Bool,
                            on reference: PullRequestReference) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        let session = credentialSession
        try await api.setReviewRequested(token: token, reference: reference, name: name, kind: kind, requested: requested)
        await requireFreshRefresh(for: session)
    }

    func fetchPullRequestChecks(_ reference: PullRequestReference) async throws -> PullRequestChecks {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        return try await api.fetchPullRequestChecks(token: token, reference: reference)
    }

    /// Reruns failed checks, then refreshes the list, whose check state goes back to pending.
    func rerunChecks(_ rerun: CheckRerun, in repoFullName: String) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        let session = credentialSession
        try await api.rerunChecks(token: token, repoFullName: repoFullName, rerun: rerun)
        await requireFreshRefresh(for: session)
    }

    /// Submits a review, then refreshes To Review, which drops a pull request once I have reviewed it.
    func submitReview(_ review: NewPullRequestReview, on reference: PullRequestReference) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        try await api.submitReview(token: token, reference: reference, review: review)
        await refreshReviewRequests()
    }

    func startPendingReview(pullRequestID: String, commitID: String) async throws -> String {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        return try await api.startPendingReview(token: token, pullRequestID: pullRequestID, commitID: commitID)
    }

    func addPendingReviewComment(_ comment: PendingReviewComment, reviewID: String) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        try await api.addPendingReviewComment(token: token, reviewID: reviewID, comment: comment)
    }

    /// Publishes the pending review with its verdict, then refreshes To Review like `submitReview`.
    func submitPendingReview(reviewID: String, event: PullRequestReviewEvent, body: String) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        try await api.submitPendingReview(token: token, reviewID: reviewID, event: event, body: body)
        await refreshReviewRequests()
    }

    func deletePendingReview(reviewID: String) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        try await api.deletePendingReview(token: token, reviewID: reviewID)
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
                let merged = try await api.mergePullRequest(token: token, repoFullName: row.repoFullName,
                                                            number: row.number, method: mergeMethod(for: row))
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
                try await api.enableAutoMerge(token: token, pullRequestID: row.nodeID, mergeMethod: mergeMethod(for: row))
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

/// Which pull request to select, and on which tab. No tab when it is on neither list, so it opens in its own window.
struct PullRequestToShow: Equatable {
    let reference: PullRequestReference
    let tab: PullRequestTab?
}

extension PRMonitor {
    func listWindowAppeared() {
        listWindowCount += 1
    }

    func listWindowDisappeared() {
        listWindowCount = max(0, listWindowCount - 1)
    }

    /// Asks the main window to show a pull request, switching to the tab that lists it.
    /// Returns false when no main window is open to show it.
    @discardableResult
    func showPullRequest(_ reference: PullRequestReference) -> Bool {
        guard listWindowCount > 0 else { return false }
        let tab: PullRequestTab?
        if prRows.contains(where: { $0.reference == reference }) {
            tab = .open
        } else if reviewRequests.rows.contains(where: { $0.reference == reference }) {
            tab = .reviews
        } else {
            tab = nil
        }
        if let tab {
            selectedTab = tab
        }
        pullRequestToShow = PullRequestToShow(reference: reference, tab: tab)
        return true
    }

    /// The method Merge and Enable auto-merge use: the one picked for the repository if it still allows it,
    /// otherwise the one GitHub suggests.
    func mergeMethod(for row: PullRequestRow) -> MergeMethod {
        let chosen = mergeMethodChoices[row.repoFullName]
            ?? defaults.string(forKey: DefaultsKeys.mergeMethod(for: row.repoFullName)).flatMap(MergeMethod.init(rawValue:))
        if let chosen, row.mergeMethods.allowed.contains(chosen) { return chosen }
        return row.mergeMethods.defaultMethod
    }

    /// Remembers the method for every pull request in the repository.
    func chooseMergeMethod(_ method: MergeMethod, for repoFullName: String) {
        mergeMethodChoices[repoFullName] = method
        defaults.set(method.rawValue, forKey: DefaultsKeys.mergeMethod(for: repoFullName))
    }
}

struct MissingTokenError: LocalizedError {
    var errorDescription: String? { "Add a GitHub token to load pull requests." }
}

private enum DefaultsKeys {
    static let notifyCheckResults = "GithubPanel.notifications.notifyCheckResults"
    static let notifyApprovals = "GithubPanel.notifications.notifyApprovals"
    static let notifyChangesRequested = "GithubPanel.notifications.notifyChangesRequested"
    static let notifyReviewsFromMe = "GithubPanel.notifications.notifyReviewsFromMe"
    static let notifyReviewsFromMyTeams = "GithubPanel.notifications.notifyReviewsFromMyTeams"

    static let refreshInterval = "GithubPanel.refreshInterval"
    static let allSucceededHookScript = "GithubPanel.hooks.allSucceededScript"
    static let anyFailuresHookScript = "GithubPanel.hooks.anyFailuresScript"

    static func mergeMethod(for repoFullName: String) -> String {
        "GithubPanel.mergeMethod.\(repoFullName)"
    }
}
