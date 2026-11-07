import Foundation

/// The only code that reads pull requests and their lists from GitHub. Callers ask for a resource, and the engine
/// fetches it, saves it to the details or lists cache, and records when in `sync_state`. Views show what lands in
/// the caches. Requests for a resource already loading join it, and requests the user waits on never queue behind
/// preloading.
actor SyncEngine {
    enum Resource: Hashable {
        case detail(PullRequestReference)
        case comments(PullRequestReference, PullRequestCommentLimits)
        case checks(PullRequestReference)
        /// The files changed between two commits of a pull request, such as the last reviewed one and the head.
        case changedFiles(PullRequestReference, base: String, head: String)
        /// My PRs.
        case openList
        /// A page of my closed and merged pull requests.
        case history(page: Int)
        /// To Review.
        case reviewRequests
        /// The token's login, which History searches by. My PRs also returns it.
        case currentUser

        /// The pull request a detail resource belongs to.
        var reference: PullRequestReference? {
            switch self {
            case .detail(let reference), .comments(let reference, _), .checks(let reference),
                 .changedFiles(let reference, _, _):
                return reference
            case .openList, .history, .reviewRequests, .currentUser:
                return nil
            }
        }

        var list: PullRequestListKind? {
            switch self {
            case .openList: return .open
            case .history(let page): return .history(page: page)
            case .reviewRequests: return .reviewRequests
            case .detail, .comments, .checks, .changedFiles, .currentUser: return nil
            }
        }

        /// The `sync_state` key. Lists use their `pull_request_list` key.
        var key: String {
            if let list { return list.key }
            switch self {
            case .detail(let reference): return "detail:\(reference.id)"
            case .comments(let reference, let limits):
                return "comments:\(reference.id):\(limits.comments):\(limits.threads)"
            case .checks(let reference): return "checks:\(reference.id)"
            case .changedFiles(let reference, let base, let head): return "changedFiles:\(reference.id):\(base)...\(head)"
            case .currentUser: return "currentUser"
            case .openList, .history, .reviewRequests: preconditionFailure("Lists use their list key")
            }
        }
    }

    enum Priority: Comparable {
        /// Preloading, such as for the rows of a list, and timer refreshes. Runs a few at a time.
        case background
        /// What the user is looking at. Starts right away.
        case userVisible
    }

    /// The token to send, and the session it belongs to. The session changes with the token, so results loaded
    /// with an old token are dropped instead of saved.
    struct Credential {
        let token: String
        let session: UUID
    }

    /// The token or account changed while the request loaded, so its result was dropped.
    struct CredentialChangedError: LocalizedError {
        var errorDescription: String? { "The GitHub token changed while this was loading." }
    }

    let cache: PullRequestDetailCache
    let lists: PullRequestListCache
    private let api: GitHubAPIClient
    private let store: LocalStore
    private let credential: @MainActor () -> Credential?
    /// The refresh interval, which the backoff is measured in.
    private let refreshInterval: @MainActor () -> TimeInterval
    private let now: @Sendable () -> Date
    private let maxBackgroundRequests: Int
    private var inFlight: [Resource: Job] = [:]
    /// Background jobs waiting for a slot, oldest first.
    private var waiting: [Job] = []
    private var runningBackground = 0
    private var backoff: Backoff?
    private let maxBackoff: TimeInterval = 30 * 60
    /// The login of the session's token, from My PRs or `.currentUser`.
    private var login: (session: UUID, login: String)?

    private final class Job {
        let id = UUID()
        let resource: Resource
        let session: UUID
        let token: String
        var priority: Priority
        /// The request for the same resource that was loading when this one was asked for. This one waits for it,
        /// so the newer result is saved last.
        let previous: Job?
        /// A list load drops its result once a newer load for it starts, since a write may have made it stale.
        var isSuperseded = false
        var task: Task<Void, Error>?
        var hasStarted = false
        var holdsBackgroundSlot = false
        var slotWaiter: CheckedContinuation<Void, Never>?

        init(resource: Resource, credential: Credential, priority: Priority, previous: Job?) {
            self.resource = resource
            session = credential.session
            token = credential.token
            self.priority = priority
            self.previous = previous
        }
    }

    /// After throttled or rejected requests, every request fails with the same error until `until`.
    private struct Backoff {
        let session: UUID
        let failures: Int
        /// When the last failure backed off. Requests sent before then failed in the same burst.
        let since: Date
        let until: Date
        let error: Error
    }

    private enum Response {
        case detail(PullRequestDetailContent)
        case comments(PullRequestComments, PullRequestCommentLimits)
        case checks(PullRequestChecks)
        case changedFiles([PullRequestFile], base: String, head: String)
        case openList(OpenPullRequests)
        case history(PullRequestHistoryPage)
        case reviewRequests(ReviewRequests)
        case currentUser(String)
    }

    init(api: GitHubAPIClient, store: LocalStore, cache: PullRequestDetailCache,
         lists: PullRequestListCache,
         credential: @escaping @MainActor () -> Credential?,
         refreshInterval: @escaping @MainActor () -> TimeInterval = { 60 },
         now: @escaping @Sendable () -> Date = { Date() }, maxBackgroundRequests: Int = 3) {
        self.api = api
        self.store = store
        self.cache = cache
        self.lists = lists
        self.credential = credential
        self.refreshInterval = refreshInterval
        self.now = now
        self.maxBackgroundRequests = maxBackgroundRequests
    }

    /// Loads `resource` into the cache unless it loaded within `maxAge`. Throws when loading fails.
    /// Refreshes after a write and reloads the user asks for pass zero, so they never reuse an older load.
    /// List refreshes that don't follow a write pass `joinsLoadInFlight`, so they share a load already sent.
    func request(_ resource: Resource, priority: Priority = .userVisible, maxAge: TimeInterval = 0,
                 joinsLoadInFlight: Bool = false) async throws {
        try await start(resource, priority: priority, maxAge: maxAge, joinsLoadInFlight: joinsLoadInFlight).value
    }

    /// Starts loading like `request` and returns the load to wait for. Callers that load several resources at once
    /// start the detail first, so comments and checks that arrive before it still find it to attach to.
    func start(_ resource: Resource, priority: Priority = .userVisible,
               maxAge: TimeInterval = 0, joinsLoadInFlight: Bool = false) async -> Task<Void, Error> {
        var fetchedAt: Date?
        if maxAge > 0, let last = await store.syncState(for: resource.key)?.fetchedAt,
           now().timeIntervalSince(last) < maxAge {
            fetchedAt = last
        }
        var (credential, isFresh) = await MainActor.run { [cache, lists, credential, fetchedAt] in
            // A fresh `sync_state` counts only while the cache still holds what loaded.
            (credential(), fetchedAt != nil && Self.cacheHolds(resource, cache: cache, lists: lists))
        }
        guard let credential else { return Task { throw MissingTokenError() } }
        if case .currentUser = resource { isFresh = isFresh && login?.session == credential.session }
        if isFresh { return Task<Void, Error> {} }
        let running = inFlight[resource].flatMap { $0.session == credential.session ? $0 : nil }
        // A load that hasn't sent its request yet is as fresh as a new one. One already sent may have read GitHub
        // before a write the caller just made, so a request that wants nothing older waits for it and loads again.
        if let running, let task = running.task, maxAge > 0 || joinsLoadInFlight || !running.hasStarted {
            if priority > running.priority { promote(running) }
            return task
        }
        if let backoff, backoff.session == credential.session, now() < backoff.until {
            let error = backoff.error
            return Task { throw error }
        }
        if let running, priority > running.priority { promote(running) }
        if let running, resource.list != nil { running.isSuperseded = true }
        let job = Job(resource: resource, credential: credential, priority: priority, previous: running)
        let task = Task { try await run(job) }
        job.task = task
        inFlight[resource] = job
        return task
    }

    /// Cancels every load and forgets when resources last loaded, such as when the account changes.
    /// Results that still arrive are dropped, since their session no longer matches.
    func reset() async {
        for job in inFlight.values { job.task?.cancel() }
        for job in waiting {
            job.slotWaiter?.resume()
            job.slotWaiter = nil
        }
        waiting = []
        backoff = nil
        login = nil
        await store.removeSyncStates()
    }

    /// Whether GitHub throttled the token or refused it, so requesting more right away would only fail again.
    static func isThrottlingError(_ error: Error) -> Bool {
        let statusCode = (error as? GraphQLError)?.statusCode ?? (error as? GitHubAPIError)?.statusCode
        guard let statusCode else { return false }
        return [401, 403, 429].contains(statusCode)
    }

    private func run(_ job: Job) async throws {
        defer { finish(job) }
        guard let list = job.resource.list else { return try await load(job) }
        await MainActor.run { [lists, credential] in
            guard credential()?.session == job.session else { return }
            lists.startLoading(list, id: job.id)
        }
        do {
            try await load(job)
        } catch {
            await stopLoading(list, job: job, error: error)
            throw error
        }
        await stopLoading(list, job: job, error: nil)
    }

    private func load(_ job: Job) async throws {
        if let previous = job.previous { _ = try? await previous.task?.value }
        await waitForSlot(job)
        job.hasStarted = true
        let attemptedAt = now()
        do {
            try Task.checkCancellation()
            let response = try await fetch(job.resource, token: job.token, session: job.session)
            if job.isSuperseded { return }
            if case .detail = job.resource {} else { await waitForDetail(of: job) }
            guard let stored = await save(response, for: job.resource, session: job.session) else {
                throw CredentialChangedError()
            }
            // A request sent before the backoff began says nothing about whether GitHub has let up.
            if let backoff, backoff.session == job.session, attemptedAt > backoff.since { self.backoff = nil }
            await store.recordSync(for: job.resource.key, attemptedAt: attemptedAt, fetchedAt: stored ? now() : nil)
        } catch {
            guard !Task.isCancelled, !(error is CredentialChangedError) else { throw CredentialChangedError() }
            if Self.isThrottlingError(error) { await backOff(after: error, sentAt: attemptedAt, session: job.session) }
            if job.isSuperseded { return }
            await store.recordSync(for: job.resource.key, attemptedAt: attemptedAt, error: error.localizedDescription)
            throw error
        }
    }

    /// Ends a list's loading state, with the error the load failed with, if the token hasn't changed since.
    private func stopLoading(_ list: PullRequestListKind, job: Job, error: Error?) async {
        await MainActor.run { [lists, credential] in
            guard credential()?.session == job.session else { return }
            if let error, !(error is CredentialChangedError) {
                lists.showError(error.localizedDescription, on: list)
            }
            lists.stopLoading(list, id: job.id)
        }
    }

    private func fetch(_ resource: Resource, token: String, session: UUID) async throws -> Response {
        switch resource {
        case .detail(let reference):
            return .detail(try await api.fetchPullRequestDetail(token: token, reference: reference))
        case .comments(let reference, let limits):
            return .comments(try await api.fetchPullRequestComments(token: token, reference: reference, limits: limits),
                             limits)
        case .checks(let reference):
            return .checks(try await api.fetchPullRequestChecks(token: token, reference: reference))
        case .changedFiles(let reference, let base, let head):
            return .changedFiles(try await api.fetchChangedFiles(token: token, repoFullName: reference.repoFullName,
                                                                 baseSHA: base, headSHA: head),
                                 base: base, head: head)
        case .openList:
            return .openList(try await api.fetchOpenPRs(token: token))
        case .history(let page):
            let login = try await login(for: session)
            return .history(try await api.fetchClosedPRs(token: token, username: login, page: page,
                                                         perPage: Self.historyPageSize))
        case .reviewRequests:
            return .reviewRequests(try await api.fetchReviewRequests(token: token))
        case .currentUser:
            return .currentUser(try await api.fetchCurrentUser(token: token).login)
        }
    }

    static let historyPageSize = 10

    /// The session's login, looked up first if My PRs hasn't returned it yet.
    private func login(for session: UUID) async throws -> String {
        if let login, login.session == session { return login.login }
        // The History load that needs it is already running, so the lookup doesn't wait for a background slot.
        try await request(.currentUser, priority: .userVisible, maxAge: .infinity)
        guard let login, login.session == session else { throw CredentialChangedError() }
        return login.login
    }

    /// Comments and checks attach to a cached detail, so they wait for one that's loading alongside them.
    private func waitForDetail(of job: Job) async {
        guard let reference = job.resource.reference, let detail = inFlight[.detail(reference)],
              detail.session == job.session else { return }
        _ = try? await detail.task?.value
    }

    /// Saves the response to the cache. Returns whether the cache kept it, or nil when the session changed.
    private func save(_ response: Response, for resource: Resource, session: UUID) async -> Bool? {
        let fetchedAt = now()
        let stored = await MainActor.run { [cache, lists, credential] () -> Bool? in
            guard credential()?.session == session else { return nil }
            if let reference = resource.reference { return Self.store(response, for: reference, in: cache) }
            switch response {
            case .openList(let result): lists.store(result, fetchedAt: fetchedAt)
            case .history(let page):
                guard case .history(let number) = resource else { break }
                lists.store(page, asPage: number, fetchedAt: fetchedAt)
            case .reviewRequests(let requests): lists.store(requests, fetchedAt: fetchedAt)
            case .currentUser, .detail, .comments, .checks, .changedFiles: break
            }
            return true
        }
        // The session still matched when the result was saved, so the login belongs to it.
        if stored != nil {
            if case .openList(let result) = response { login = (session, result.login) }
            if case .currentUser(let user) = response { login = (session, user) }
        }
        return stored
    }

    @MainActor
    private static func store(_ response: Response, for reference: PullRequestReference,
                              in cache: PullRequestDetailCache) -> Bool {
        switch response {
        case .detail(let content):
            cache.store(content)
            return true
        case .comments(let comments, let limits):
            return cache.store(comments, for: reference, limits: limits)
        case .checks(let checks):
            // Checks are for the head commit, which only the detail knows.
            guard let headSHA = cache.entry(for: reference)?.content.detail.headSHA else { return false }
            return cache.store(checks, for: reference, headSHA: headSHA)
        case .changedFiles(let files, let base, let head):
            return cache.storeChanges(files, for: reference, baseSHA: base, headSHA: head)
        case .openList, .history, .reviewRequests, .currentUser:
            return false
        }
    }

    @MainActor
    private static func cacheHolds(_ resource: Resource, cache: PullRequestDetailCache,
                                   lists: PullRequestListCache) -> Bool {
        if let list = resource.list { return lists.holds(list) }
        guard let reference = resource.reference else { return true }
        guard let entry = cache.entry(for: reference) else { return false }
        switch resource {
        case .detail: return true
        case .comments(_, let limits): return entry.comments != nil && entry.commentLimits == limits
        case .checks: return entry.checks != nil
        case .changedFiles(_, let base, let head):
            return entry.filesSinceLastReview != nil && entry.content.detail.lastReviewedSHA == base
                && entry.content.detail.headSHA == head
        case .openList, .history, .reviewRequests, .currentUser:
            return false
        }
    }

    /// Backs off for two refresh intervals after the first failure, doubling after each one up to 30 minutes.
    /// Requests sent alongside the one that failed fail with it, so they don't count as more failures.
    private func backOff(after error: Error, sentAt: Date, session: UUID) async {
        let interval = await MainActor.run { [refreshInterval] in refreshInterval() }
        let current = backoff?.session == session ? backoff : nil
        if let current, sentAt <= current.since { return }
        let failures = (current?.failures ?? 0) + 1
        let delay = min(interval * pow(2, Double(failures)), max(interval, maxBackoff))
        // Timer ticks run on a fixed cadence that started before this request failed, so allow half an interval
        // of slack; otherwise the tick due when the backoff ends would be skipped.
        let failedAt = now()
        backoff = Backoff(session: session, failures: failures, since: failedAt,
                          until: failedAt.addingTimeInterval(delay - interval / 2), error: error)
    }

    // MARK: - Priority

    /// Background jobs run a few at a time. User-visible ones start right away.
    private func waitForSlot(_ job: Job) async {
        guard job.priority == .background, !Task.isCancelled else { return }
        guard runningBackground >= maxBackgroundRequests else {
            runningBackground += 1
            job.holdsBackgroundSlot = true
            return
        }
        await withCheckedContinuation { continuation in
            job.slotWaiter = continuation
            waiting.append(job)
        }
    }

    /// Lets a queued job start now that the user is waiting for it.
    private func promote(_ job: Job) {
        job.priority = .userVisible
        if let previous = job.previous { promote(previous) }
        guard let waiter = job.slotWaiter else { return }
        job.slotWaiter = nil
        waiting.removeAll { $0 === job }
        waiter.resume()
    }

    private func finish(_ job: Job) {
        if inFlight[job.resource] === job { inFlight[job.resource] = nil }
        guard job.holdsBackgroundSlot else { return }
        job.holdsBackgroundSlot = false
        runningBackground -= 1
        while runningBackground < maxBackgroundRequests, !waiting.isEmpty {
            let next = waiting.removeFirst()
            runningBackground += 1
            next.holdsBackgroundSlot = true
            next.slotWaiter?.resume()
            next.slotWaiter = nil
        }
    }
}
