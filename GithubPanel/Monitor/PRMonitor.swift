import Foundation
import Combine
/// Shows the lists the sync engine loads into `cache`, and keeps the settings, notifications, check hooks,
/// For Later and hidden review requests. It asks the engine for everything it shows rather than fetching itself.
@MainActor
final class PRMonitor: ObservableObject {
    @Published private(set) var prRows: [PullRequestRow] = []
    /// My PRs parked under For Later, keyed by pull request ID. Also saved to defaults.
    @Published private(set) var forLaterIDs: Set<String> = []
    @Published private(set) var historyRows: [PullRequestHistoryRow] = []
    @Published private(set) var reviewRequests: ReviewRequests = .empty
    @Published var selectedTab: PullRequestTab = .open {
        didSet {
            guard selectedTab != oldValue else { return }
            loadSelectedTab()
        }
    }
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isHistoryLoading: Bool = false
    @Published private(set) var isReviewRequestsLoading: Bool = false
    @Published var hasToken: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastHistoryError: String?
    @Published private(set) var lastReviewRequestsError: String?
    /// Set when the last open pull request refresh left some out because the token isn't SSO-authorized.
    @Published private(set) var openPullRequestsSSOAuthorizationURL: URL?
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastHistoryRefreshAt: Date?
    @Published private(set) var lastReviewRequestsRefreshAt: Date?
    @Published private(set) var historyPage: Int = 1
    @Published private(set) var historyTotalCount: Int = 0
    let isUsingMockData: Bool
    /// A pull request a clicked notification asked to show. The main window selects it, then clears this.
    @Published var pullRequestToShow: PullRequestToShow?
    /// Pull requests loaded so far, one record each: My PRs, To Review and History with their loading and error
    /// state, and the details and comments every detail view shares.
    let cache: PullRequestCache
    /// Loads pull requests and lists into the cache with the session token.
    private(set) lazy var syncEngine = SyncEngine(
        api: api, store: store, cache: cache,
        credential: { [weak self] in self?.syncCredential },
        refreshInterval: { [weak self] in self?.refreshInterval ?? 60 },
        now: { [dateProvider] in dateProvider.now })
    /// Refreshes My PRs and To Review every `refreshInterval`.
    private(set) lazy var refreshScheduler = ListRefreshScheduler(
        timerScheduler: timerScheduler,
        interval: { [weak self] in self?.refreshInterval ?? 60 },
        refresh: { [weak self] priority, maxAge in await self?.refreshLists(priority: priority, maxAge: maxAge) })
    @Published var refreshInterval: TimeInterval {
        didSet {
            defaults.set(refreshInterval, forKey: DefaultsKeys.refreshInterval)
            refreshScheduler.schedule()
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
    private let store: LocalStore
    private let tokenStore: TokenStoring
    private let notificationPoster: NotificationPosting
    private let defaults: DefaultsStoring
    private let timerScheduler: TimerScheduling
    private let dateProvider: DateProviding
    private let hookRunner: PullRequestHookRunning
    private var credentialSession = UUID()
    private var didLoadSessionToken = false
    private var sessionToken: String?
    private var listSubscription: AnyCancellable?
    /// How many times My PRs or To Review loaded, so a timer tick that loaded neither preloads nothing.
    private var listLoadCount = 0
    /// The History page shown, or being loaded to replace it.
    private var requestedHistoryPage = 1
    private var prefetchTask: Task<Void, Never>?
    private var pendingPrefetch: [PullRequestReference: PendingPrefetch] = [:]
    private var lastStates: [String: CheckState] = [:]
    private var lastReviewStatuses: [String: PullRequestReviewStatus] = [:]
    /// Review requests seen since the token was set. Nil until the first load, so the first list posts nothing.
    private var knownReviewRequestIDs: [ReviewRequestGroup: Set<String>]?
    /// Review requests hidden from To Review, keyed by pull request ID. Also saved to defaults.
    private var hiddenReviewRequests: [String: HiddenReviewRequest] = [:]
    /// Main windows showing the list. A clicked notification opens GitHub while there are none.
    private var listWindowCount = 0
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
         isUsingMockData: Bool = false,
         store: LocalStore = .inMemory()) {
        self.api = api
        // Mock data never reads or writes the saved store, so it can't mix with real pull requests.
        self.store = isUsingMockData ? .inMemory() : store
        cache = PullRequestCache(store: self.store)
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
        hiddenReviewRequests = defaults.string(forKey: DefaultsKeys.hiddenReviewRequests)
            .flatMap { try? JSONDecoder().decode([String: HiddenReviewRequest].self, from: Data($0.utf8)) } ?? [:]
        forLaterIDs = ForLaterStorage.decode(defaults.string(forKey: DefaultsKeys.forLaterPullRequests))
        if !isUsingMockData {
            // The lists used to be saved to defaults. They're only caches, so they're dropped rather than imported.
            defaults.removeObject(forKey: DefaultsKeys.legacyCachedMyPullRequests)
            defaults.removeObject(forKey: DefaultsKeys.legacyCachedReviewRequests)
        }
        // The lists saved by the last run show until the first refresh replaces them. They post no notifications.
        showOpenPullRequests()
        showReviewRequests()
        showHistory()
        listSubscription = cache.listUpdates.sink { [weak self] change in self?.listChanged(change) }
    }

    func start() {
        hasToken = loadSessionToken() != nil
        refresh()
        refreshScheduler.schedule()
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
        lastStates = [:]
        cache.removeLists()
        requestedHistoryPage = 1
        historyPage = 1
        historyTotalCount = 0
        setHistoryRows([])
        showOpenPullRequests()
        showReviewRequests()
        showHistory()
    }

    private func invalidateLogin() {
        credentialSession = UUID()
        Task { [syncEngine] in await syncEngine.reset() }
        prefetchTask?.cancel()
        prefetchTask = nil
        pendingPrefetch = [:]
        lastReviewStatuses = [:]
        knownReviewRequestIDs = nil
        cache.removeDetails()
        cache.stopAllLoading()
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

    private var syncCredential: SyncEngine.Credential? {
        loadSessionToken().map { SyncEngine.Credential(token: $0, session: credentialSession) }
    }

    /// Refreshes My PRs and To Review together. App start, timer ticks and manual refresh on
    /// either tab all come through here, so switching between the two tabs never fetches.
    func refreshNow() async {
        await refreshLists(priority: .userVisible, maxAge: 0)
    }

    /// Asks the engine for both lists, sharing a load already in flight, then preloads their rows.
    /// Also sends the changes still waiting, such as ones saved before a restart or held back by a backoff.
    private func refreshLists(priority: SyncEngine.Priority, maxAge: TimeInterval) async {
        guard loadSessionToken() != nil else { return }
        let session = credentialSession
        let loadCount = listLoadCount
        let engine = syncEngine
        await engine.sendPendingChanges()
        async let reviewRequests: Void? = try? engine.request(.reviewRequests, priority: priority, maxAge: maxAge,
                                                              joinsLoadInFlight: true)
        _ = try? await engine.request(.openList, priority: priority, maxAge: maxAge, joinsLoadInFlight: true)
        _ = await reviewRequests
        guard session == credentialSession, priority == .userVisible || listLoadCount != loadCount else { return }
        prefetchDetails()
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
        historyPage * SyncEngine.historyPageSize < historyTotalCount && !isHistoryLoading
    }

    var historyRangeText: String {
        guard !historyRows.isEmpty else {
            return historyTotalCount == 0 ? "No history" : "Page \(historyPage)"
        }
        let start = ((historyPage - 1) * SyncEngine.historyPageSize) + 1
        let end = start + historyRows.count - 1
        return "\(start)-\(end) of \(historyTotalCount)"
    }

    /// Shows the page as last loaded, if it has been, while it loads again.
    private func refreshHistory(page: Int) async {
        guard loadSessionToken() != nil else { return }
        requestedHistoryPage = page
        showHistory()
        _ = try? await syncEngine.request(.history(page: page), joinsLoadInFlight: true)
    }

    /// Refreshes To Review alone, such as after submitting a review, then preloads its rows.
    func refreshReviewRequests() async {
        guard loadSessionToken() != nil else { return }
        let session = credentialSession
        _ = try? await syncEngine.request(.reviewRequests)
        guard session == credentialSession else { return }
        prefetchDetails()
    }

    /// Both tabs share a queue. A refresh arriving during preloading queues another pass rather than being dropped.
    /// The queue takes the two lists' rows in turn from the top, so the rows each tab selects first load first.
    private func prefetchDetails() {
        guard loadSessionToken() != nil else { return }
        for (position, row) in prRows.enumerated() {
            queuePrefetch(row.reference, updatedAt: row.updatedAt, position: position)
        }
        for (position, row) in reviewRequests.rows.enumerated() {
            queuePrefetch(row.reference, updatedAt: row.updatedAt, position: position)
        }
        guard prefetchTask == nil, !pendingPrefetch.isEmpty else { return }
        let session = credentialSession
        prefetchTask = Task { @MainActor [weak self] in
            await self?.prefetch(session: session)
        }
    }

    private func queuePrefetch(_ reference: PullRequestReference, updatedAt: Date, position: Int) {
        let queued = pendingPrefetch[reference]
        pendingPrefetch[reference] = PendingPrefetch(updatedAt: max(queued?.updatedAt ?? .distantPast, updatedAt),
                                                     position: min(queued?.position ?? position, position))
    }

    /// Asks the sync engine for each queued pull request in the background, one pull request at a time.
    private func prefetch(session: UUID) async {
        defer {
            if session == credentialSession { prefetchTask = nil }
        }
        while let reference = PendingPrefetch.next(in: pendingPrefetch),
              let updatedAt = pendingPrefetch.removeValue(forKey: reference)?.updatedAt {
            guard !Task.isCancelled, session == credentialSession else { return }
            do {
                let cached = cache.entry(for: reference)
                var loads: [Task<Void, Error>] = []
                if cache.needsRefresh(reference, updatedAt: updatedAt) {
                    let limits = cached?.commentLimits ?? PullRequestCommentLimits()
                    loads.append(await syncEngine.start(.detail(reference), priority: .background))
                    loads.append(await syncEngine.start(.comments(reference, limits), priority: .background))
                }
                // Check results can change without changing the PR's updatedAt, so they load on every pass.
                // They load alongside the content, so the content is cached without waiting for them.
                loads.append(await syncEngine.start(.checks(reference), priority: .background))
                for load in loads { try await load.value }
            } catch {
                if SyncEngine.isThrottlingError(error) {
                    pendingPrefetch = [:]
                    return
                }
            }
        }
    }

    /// Waits for the background detail prefetch to finish. Used by tests.
    func waitForPrefetch() async {
        await prefetchTask?.value
    }

    private func requireFreshRefresh(for session: UUID) async {
        guard session == credentialSession else { return }
        _ = try? await syncEngine.request(.openList)
        guard session == credentialSession else { return }
        prefetchDetails()
    }

    // MARK: - Showing the lists

    private func listChanged(_ change: PullRequestCache.ListChange) {
        switch change {
        case .loaded(.open):
            listLoadCount += 1
            let rows = cache.open ?? []
            updateNotificationsForRows(rows)
            forgetClosedForLater(openRows: rows, isComplete: cache.openSSOAuthorizationURL == nil)
            showOpenPullRequests()
        case .loaded(.reviewRequests):
            listLoadCount += 1
            notifyAboutNewReviewRequests(cache.reviewRequests ?? .empty)
            showReviewRequests()
        case .changed(.open):
            showOpenPullRequests()
        case .changed(.reviewRequests):
            showReviewRequests()
        case .loaded(.history(let page)), .changed(.history(let page)):
            guard page == requestedHistoryPage else { return }
            showHistory()
        }
    }

    private func showOpenPullRequests() {
        let state = cache.state(of: .open)
        setPRRows(cache.open ?? [])
        openPullRequestsSSOAuthorizationURL = cache.openSSOAuthorizationURL
        isLoading = state.isLoading
        // Keep the last list on screen; the error shows above it until a refresh succeeds.
        lastError = state.lastError
        lastRefreshAt = state.fetchedAt
    }

    /// Shows the History page asked for, as last loaded. A failed load empties it.
    private func showHistory() {
        let page = cache.historyPage(requestedHistoryPage)
        let state = cache.state(of: .history(page: requestedHistoryPage))
        isHistoryLoading = state.isLoading
        lastHistoryError = state.lastError
        if state.lastError != nil {
            setHistoryRows([])
            historyTotalCount = 0
        } else if let page {
            setHistoryRows(page.rows)
            historyPage = page.page
            historyTotalCount = page.totalCount
        }
        if let fetchedAt = state.fetchedAt { lastHistoryRefreshAt = fetchedAt }
    }

    private func setPRRows(_ rows: [PullRequestRow]) {
        guard prRows != rows else { return }
        prRows = rows
    }

    /// My PRs in their status groups, then the ones under For Later.
    var myPullRequests: MyPullRequestSections {
        myPullRequests(botReviewer: nil)
    }

    /// My PRs in their status groups, counting the review bot's review like a person's. `botReviewer` is a login
    /// from ``BotReviewer/normalized(_:)``.
    func myPullRequests(botReviewer: String?) -> MyPullRequestSections {
        MyPullRequestSections(rows: prRows, forLaterIDs: forLaterIDs, botReviewer: botReviewer)
    }

    /// Parks a pull request under For Later on My PRs, until it is moved back, merged or closed.
    func moveToForLater(_ row: PullRequestRow) {
        setForLaterIDs(forLaterIDs.union([row.id]))
    }

    /// Moves a pull request from For Later back up with the others on My PRs.
    func moveOutOfForLater(_ row: PullRequestRow) {
        setForLaterIDs(forLaterIDs.subtracting([row.id]))
    }

    /// Forgets For Later pull requests that are no longer open, so a reopened one starts back on My PRs.
    /// Keeps them all when SSO hid some of the list, since a hidden one may still be open.
    private func forgetClosedForLater(openRows: [PullRequestRow], isComplete: Bool) {
        guard isComplete else { return }
        setForLaterIDs(forLaterIDs.intersection(openRows.map(\.id)))
    }

    private func setForLaterIDs(_ ids: Set<String>) {
        guard ids != forLaterIDs else { return }
        forLaterIDs = ids
        defaults.set(ForLaterStorage.encode(ids), forKey: DefaultsKeys.forLaterPullRequests)
    }

    private func setHistoryRows(_ rows: [PullRequestHistoryRow]) {
        guard historyRows != rows else { return }
        historyRows = rows
    }

    private func setReviewRequests(_ requests: ReviewRequests) {
        guard reviewRequests != requests else { return }
        reviewRequests = requests
    }

    /// Hides a review request from To Review until new commits are pushed or my review is requested again.
    func hideReviewRequest(_ row: ReviewRequestRow) {
        hiddenReviewRequests[row.id] = HiddenReviewRequest(row)
        saveHiddenReviewRequests()
        setReviewRequests(reviewRequests.removing { $0.id == row.id })
    }

    /// Shows the loaded review requests that are not hidden. Forgets hidden requests that changed
    /// or are no longer waiting on me, so they show again if they come back.
    private func showReviewRequests() {
        let state = cache.state(of: .reviewRequests)
        isReviewRequestsLoading = state.isLoading
        // Keep the last list on screen; the error shows above it until a refresh succeeds.
        lastReviewRequestsError = state.lastError
        lastReviewRequestsRefreshAt = state.fetchedAt
        // Before any list loads there is nothing to tell which hidden requests are gone.
        guard let fetchedReviewRequests = cache.reviewRequests else { return setReviewRequests(.empty) }
        let rows = Dictionary(fetchedReviewRequests.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stillHidden = hiddenReviewRequests.filter { id, hidden in rows[id].map(hidden.hides) ?? false }
        if stillHidden != hiddenReviewRequests {
            hiddenReviewRequests = stillHidden
            saveHiddenReviewRequests()
        }
        setReviewRequests(fetchedReviewRequests.removing { stillHidden[$0.id] != nil })
    }

    private func saveHiddenReviewRequests() {
        guard let data = try? JSONEncoder().encode(hiddenReviewRequests) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: DefaultsKeys.hiddenReviewRequests)
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

    /// How long to wait before each load that looks for the commit Update branch makes.
    var branchUpdatePollDelays: [TimeInterval] = [1, 2, 3, 5]

    /// Merges the base branch into the pull request's branch, then refreshes the list, whose merge state changes.
    /// GitHub makes the merge commit after it answers, so a refresh right away would still show the old head and its
    /// checks. The detail reloads until the head changes, which shows the new commit in the lists with its checks
    /// pending, and the list refreshes after that.
    func updatePullRequestBranch(_ reference: PullRequestReference, pullRequestID: String,
                                 expectedHeadSHA: String) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        let session = credentialSession
        try await api.updatePullRequestBranch(token: token, pullRequestID: pullRequestID, expectedHeadSHA: expectedHeadSHA)
        await waitForNewHead(of: reference, replacing: expectedHeadSHA, session: session)
        await requireFreshRefresh(for: session)
    }

    private func waitForNewHead(of reference: PullRequestReference, replacing headSHA: String, session: UUID) async {
        for delay in branchUpdatePollDelays {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard session == credentialSession, !Task.isCancelled else { return }
            _ = try? await syncEngine.request(.detail(reference))
            if let head = cache.entry(for: reference)?.content.detail.headSHA, head != headSHA { return }
        }
    }

    func fetchReviewerCandidates(_ reference: PullRequestReference, query: String) async throws -> [ReviewerCandidate] {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        return try await api.fetchReviewerCandidates(token: token, reference: reference, query: query)
    }

    func searchMentionCandidates(_ reference: PullRequestReference, query: String) async throws -> [MentionCandidate] {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        return try await api.searchMentionCandidates(token: token, reference: reference, query: query)
    }

    /// Reruns failed checks, then refreshes the list, whose check state goes back to pending.
    func rerunChecks(_ rerun: CheckRerun, in repoFullName: String) async throws {
        guard let token = loadSessionToken() else { throw MissingTokenError() }
        let session = credentialSession
        try await api.rerunChecks(token: token, repoFullName: repoFullName, rerun: rerun)
        await requireFreshRefresh(for: session)
    }

    func requestMarkReady(for row: PullRequestRow) async {
        guard row.isDraft, let token = loadSessionToken() else { return }
        let session = credentialSession
        do {
            try await api.markPullRequestReadyForReview(token: token, pullRequestID: row.nodeID)
            await requireFreshRefresh(for: session)
        } catch {
            guard session == credentialSession else { return }
            cache.showError(error.localizedDescription, on: .open)
        }
    }

    func requestMerge(for row: PullRequestRow) async {
        guard !row.isDraft, let token = loadSessionToken() else { return }
        let session = credentialSession
        do {
            // Use the same resolver as the merge button so the label and the action cannot drift apart.
            switch MergeButtonState.resolve(for: row, isWorking: false) {
            case .enqueue:
                try await api.enqueuePullRequest(token: token, pullRequestID: row.nodeID)
                await requireFreshRefresh(for: session)
            case .merge:
                let merged = try await api.mergePullRequest(token: token, repoFullName: row.repoFullName,
                                                            number: row.number, method: mergeMethod(for: row))
                guard session == credentialSession else { return }
                if merged {
                    cache.removeOpenPullRequest(id: row.id)
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
            cache.showError(error.localizedDescription, on: .open)
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
    static let hiddenReviewRequests = "GithubPanel.hiddenReviewRequests"
    static let forLaterPullRequests = "GithubPanel.forLaterPullRequests"
    /// Where the lists were saved before the local store. Removed at launch.
    static let legacyCachedMyPullRequests = "GithubPanel.cache.myPullRequests"
    static let legacyCachedReviewRequests = "GithubPanel.cache.reviewRequests"

    static func mergeMethod(for repoFullName: String) -> String {
        "GithubPanel.mergeMethod.\(repoFullName)"
    }
}

/// A pull request waiting for its details to preload.
struct PendingPrefetch: Equatable {
    /// The newest update seen, so the cache refreshes when it is older.
    let updatedAt: Date
    /// The row's place in its list. A pull request in both lists keeps the higher place.
    let position: Int

    /// The pull request to preload next: the highest in its list, with ties broken by id.
    static func next(in queue: [PullRequestReference: PendingPrefetch]) -> PullRequestReference? {
        queue.min { ($0.value.position, $0.key.id) < ($1.value.position, $1.key.id) }?.key
    }
}
