import Foundation

/// The only code that loads pull request details from GitHub. Callers ask for a resource, and the engine fetches it,
/// saves it to the details cache, and records when in `sync_state`. Views show what lands in the cache.
/// Requests for a resource already loading join it, and requests the user waits on never queue behind preloading.
actor SyncEngine {
    enum Resource: Hashable {
        case detail(PullRequestReference)
        case comments(PullRequestReference, PullRequestCommentLimits)
        case checks(PullRequestReference)
        /// The files changed between two commits of a pull request, such as the last reviewed one and the head.
        case changedFiles(PullRequestReference, base: String, head: String)

        var reference: PullRequestReference {
            switch self {
            case .detail(let reference), .comments(let reference, _), .checks(let reference),
                 .changedFiles(let reference, _, _):
                return reference
            }
        }

        /// The `sync_state` key.
        var key: String {
            switch self {
            case .detail(let reference): return "detail:\(reference.id)"
            case .comments(let reference, let limits):
                return "comments:\(reference.id):\(limits.comments):\(limits.threads)"
            case .checks(let reference): return "checks:\(reference.id)"
            case .changedFiles(let reference, let base, let head): return "changedFiles:\(reference.id):\(base)...\(head)"
            }
        }
    }

    enum Priority: Comparable {
        /// Preloading, such as for the rows of a list. Runs a few at a time.
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
    private let api: GitHubAPIClient
    private let store: LocalStore
    private let credential: @MainActor () -> Credential?
    private let now: @Sendable () -> Date
    private let maxBackgroundRequests: Int
    private var inFlight: [Resource: Job] = [:]
    /// Background jobs waiting for a slot, oldest first.
    private var waiting: [Job] = []
    private var runningBackground = 0
    private var backoff: Backoff?
    private let maxBackoff: TimeInterval = 30 * 60
    private let firstBackoff: TimeInterval = 60

    private final class Job {
        let resource: Resource
        let session: UUID
        let token: String
        var priority: Priority
        /// The request for the same resource that was loading when this one was asked for. This one waits for it,
        /// so the newer result is saved last.
        let previous: Job?
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
        let until: Date
        let error: Error
    }

    private enum Response {
        case detail(PullRequestDetailContent)
        case comments(PullRequestComments, PullRequestCommentLimits)
        case checks(PullRequestChecks)
        case changedFiles([PullRequestFile], base: String, head: String)
    }

    init(api: GitHubAPIClient, store: LocalStore, cache: PullRequestDetailCache,
         credential: @escaping @MainActor () -> Credential?,
         now: @escaping @Sendable () -> Date = { Date() }, maxBackgroundRequests: Int = 3) {
        self.api = api
        self.store = store
        self.cache = cache
        self.credential = credential
        self.now = now
        self.maxBackgroundRequests = maxBackgroundRequests
    }

    /// Loads `resource` into the cache unless it loaded within `maxAge`. Throws when loading fails.
    /// Refreshes after a write and reloads the user asks for pass zero, so they never reuse an older load.
    func request(_ resource: Resource, priority: Priority = .userVisible, maxAge: TimeInterval = 0) async throws {
        try await start(resource, priority: priority, maxAge: maxAge).value
    }

    /// Starts loading like `request` and returns the load to wait for. Callers that load several resources at once
    /// start the detail first, so comments and checks that arrive before it still find it to attach to.
    func start(_ resource: Resource, priority: Priority = .userVisible,
               maxAge: TimeInterval = 0) async -> Task<Void, Error> {
        var fetchedAt: Date?
        if maxAge > 0, let last = await store.syncState(for: resource.key)?.fetchedAt,
           now().timeIntervalSince(last) < maxAge {
            fetchedAt = last
        }
        let (credential, isFresh) = await MainActor.run { [cache, credential, fetchedAt] in
            // A fresh `sync_state` counts only while the cache still holds what loaded.
            (credential(), fetchedAt != nil && Self.cacheHolds(resource, cache: cache))
        }
        guard let credential else { return Task { throw MissingTokenError() } }
        if isFresh { return Task<Void, Error> {} }
        let running = inFlight[resource].flatMap { $0.session == credential.session ? $0 : nil }
        // A load that hasn't sent its request yet is as fresh as a new one. One already sent may have read GitHub
        // before a write the caller just made, so a request that wants nothing older waits for it and loads again.
        if let running, let task = running.task, maxAge > 0 || !running.hasStarted {
            if priority > running.priority { promote(running) }
            return task
        }
        if let backoff, backoff.session == credential.session, now() < backoff.until {
            let error = backoff.error
            return Task { throw error }
        }
        if let running, priority > running.priority { promote(running) }
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
        if let previous = job.previous { _ = try? await previous.task?.value }
        await waitForSlot(job)
        job.hasStarted = true
        let attemptedAt = now()
        do {
            try Task.checkCancellation()
            let response = try await fetch(job.resource, token: job.token)
            if case .detail = job.resource {} else { await waitForDetail(of: job) }
            guard let stored = await save(response, for: job.resource.reference, session: job.session) else {
                throw CredentialChangedError()
            }
            if backoff?.session == job.session { backoff = nil }
            await store.recordSync(for: job.resource.key, attemptedAt: attemptedAt, fetchedAt: stored ? now() : nil)
        } catch {
            guard !Task.isCancelled, !(error is CredentialChangedError) else { throw CredentialChangedError() }
            if Self.isThrottlingError(error) { backOff(after: error, session: job.session) }
            await store.recordSync(for: job.resource.key, attemptedAt: attemptedAt, error: error.localizedDescription)
            throw error
        }
    }

    private func fetch(_ resource: Resource, token: String) async throws -> Response {
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
        }
    }

    /// Comments and checks attach to a cached detail, so they wait for one that's loading alongside them.
    private func waitForDetail(of job: Job) async {
        guard let detail = inFlight[.detail(job.resource.reference)], detail.session == job.session else { return }
        _ = try? await detail.task?.value
    }

    /// Saves the response to the cache. Returns whether the cache kept it, or nil when the session changed.
    private func save(_ response: Response, for reference: PullRequestReference, session: UUID) async -> Bool? {
        await MainActor.run { [cache, credential] in
            guard credential()?.session == session else { return nil }
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
            }
        }
    }

    @MainActor
    private static func cacheHolds(_ resource: Resource, cache: PullRequestDetailCache) -> Bool {
        guard let entry = cache.entry(for: resource.reference) else { return false }
        switch resource {
        case .detail: return true
        case .comments(_, let limits): return entry.comments != nil && entry.commentLimits == limits
        case .checks: return entry.checks != nil
        case .changedFiles(_, let base, let head):
            return entry.filesSinceLastReview != nil && entry.content.detail.lastReviewedSHA == base
                && entry.content.detail.headSHA == head
        }
    }

    private func backOff(after error: Error, session: UUID) {
        let failures = (backoff?.session == session ? backoff?.failures ?? 0 : 0) + 1
        let delay = min(firstBackoff * pow(2, Double(failures - 1)), maxBackoff)
        backoff = Backoff(session: session, failures: failures, until: now().addingTimeInterval(delay), error: error)
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
