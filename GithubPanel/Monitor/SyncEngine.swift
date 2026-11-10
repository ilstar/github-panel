import Foundation

/// The only code that reads pull requests and their lists from GitHub. Callers ask for a resource, and the engine
/// fetches it, saves it to the details or lists cache, and records when in `sync_state`. Views show what lands in
/// the caches. Requests for a resource already loading join it, and requests the user waits on never queue behind
/// preloading. It also sends the changes the user makes, which wait in the details cache until GitHub confirms them.
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
    /// The loop sending each pull request's changes.
    private var senders: [PullRequestReference: Sender] = [:]
    /// Pull requests asked to send since their loop last looked for a change, so a change added while the loop
    /// finishes isn't left behind.
    private var sendRequests: Set<PullRequestReference> = []

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

    private final class Sender {
        var task: Task<Void, Never>?
    }

    /// What GitHub returned for a change it took.
    private enum SendResult {
        case sent
        /// The REST ID of the comment or review it posted.
        case posted(commentID: Int)
        /// The node ID of the pending review it started.
        case startedReview(id: String)
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
        for sender in senders.values { sender.task?.cancel() }
        senders = [:]
        sendRequests = []
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
            guard let stored = await save(response, for: job.resource, session: job.session,
                                          sentAt: attemptedAt) else {
                throw CredentialChangedError()
            }
            // A request sent before the backoff began says nothing about whether GitHub has let up.
            if let backoff, backoff.session == job.session, attemptedAt > backoff.since {
                self.backoff = nil
                Task { await sendPendingChanges() }
            }
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
    /// `sentAt` orders the head commit and checks it saw against other loads, which may arrive in any order.
    private func save(_ response: Response, for resource: Resource, session: UUID, sentAt: Date) async -> Bool? {
        let fetchedAt = now()
        let stored = await MainActor.run { [cache, lists, credential] () -> Bool? in
            guard credential()?.session == session else { return nil }
            if let reference = resource.reference {
                return Self.store(response, for: reference, in: cache, lists: lists, sentAt: sentAt)
            }
            switch response {
            case .openList(let result): lists.store(result, fetchedAt: fetchedAt, observedAt: sentAt)
            case .history(let page):
                guard case .history(let number) = resource else { break }
                lists.store(page, asPage: number, fetchedAt: fetchedAt)
            case .reviewRequests(let requests): lists.store(requests, fetchedAt: fetchedAt, observedAt: sentAt)
            case .currentUser(let login): lists.viewerLogin = login
            case .detail, .comments, .checks, .changedFiles: break
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
                              in cache: PullRequestDetailCache, lists: PullRequestListCache, sentAt: Date) -> Bool {
        switch response {
        case .detail(let content):
            cache.store(content)
            // A new head shows in the lists right away, with its checks pending until they load.
            lists.observe(PullRequestStatus(headSHA: content.detail.headSHA, checkState: nil, observedAt: sentAt),
                          for: reference)
            return true
        case .comments(let comments, let limits):
            return cache.store(comments, for: reference, limits: limits)
        case .checks(let checks):
            // Checks are for the head commit, which only the detail knows.
            guard let headSHA = cache.entry(for: reference)?.content.detail.headSHA,
                  cache.store(checks, for: reference, headSHA: headSHA) else { return false }
            lists.observe(PullRequestStatus(headSHA: headSHA, checkState: checks.checkState, observedAt: sentAt),
                          for: reference)
            return true
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

    // MARK: - Pending changes

    /// Sends the changes waiting in the cache for `reference`, or for every pull request, unless they're already
    /// sending. Returns once sending has started. Each pull request sends one change at a time, oldest first, while
    /// different pull requests send at the same time. During a backoff the changes wait, and send once it ends.
    func sendPendingChanges(for reference: PullRequestReference? = nil) async {
        let references: [PullRequestReference]
        if let reference {
            references = [reference]
        } else {
            // Changes saved by the last run are sent again: each sets a value, so sending one twice is safe.
            await cache.waitForRestore()
            references = await MainActor.run { [cache] in cache.referencesWithChangesToSend }
        }
        for reference in references {
            sendRequests.insert(reference)
            guard senders[reference] == nil else { continue }
            let sender = Sender()
            senders[reference] = sender
            sender.task = Task { await sendChanges(of: reference, sender: sender) }
        }
    }

    /// Waits until no changes are sending. Used by tests.
    func waitForPendingChanges() async {
        while let task = senders.values.first?.task {
            await task.value
        }
    }

    private func sendChanges(of reference: PullRequestReference, sender: Sender) async {
        defer {
            if senders[reference] === sender { senders[reference] = nil }
        }
        while !Task.isCancelled {
            sendRequests.remove(reference)
            let (credential, next) = await MainActor.run { [cache, credential] in
                (credential(), cache.nextChangeToSend(for: reference))
            }
            guard let credential, let change = next else {
                if sendRequests.contains(reference) { continue }
                return
            }
            // The change stays pending, and the request that ends the backoff starts sending again.
            if let backoff, backoff.session == credential.session, now() < backoff.until { return }
            guard let isSending = await readCache(session: credential.session, { $0.markSending(change.id) }) else {
                return
            }
            // Discarded since it was picked.
            guard isSending else { continue }
            let result: SendResult
            do {
                result = try await send(change.kind, on: reference, token: credential.token)
            } catch {
                guard !Task.isCancelled else { return }
                // GitHub answers a write it doesn't allow with 403 too, so a failed write doesn't start the backoff.
                // Nothing is sent again on its own, so a comment or review that may have posted waits for the user.
                // Changes to a pending review that didn't start fail in turn when they come up.
                await updateCache(session: credential.session) {
                    $0.markFailed(change.id, error: Self.failureMessage(for: change, error: error, cache: $0))
                }
                if !change.kind.isSafeToResend, Self.mayHaveReachedGitHub(error) {
                    // Shows what GitHub did, if it did, so the user can tell before retrying.
                    let resources = await MainActor.run { [cache] in Self.resources(changedBy: change, cache: cache) }
                    for resource in resources { _ = try? await request(resource) }
                }
                continue
            }
            switch result {
            case .sent:
                break
            case .posted(let commentID):
                await updateCache(session: credential.session) { $0.markPosted(change.id, commentID: commentID) }
            case .startedReview(let reviewID):
                // The changes waiting for this review go to it from now on.
                await updateCache(session: credential.session) { $0.markStarted(change.id, reviewID: reviewID) }
            }
            await confirm(change, session: credential.session)
        }
    }

    /// Sends a change, and returns what GitHub posted or started for it.
    private func send(_ kind: PendingChange.Kind, on reference: PullRequestReference,
                      token: String) async throws -> SendResult {
        switch kind {
        case .title(let title):
            try await api.editPullRequest(token: token, reference: reference, title: title, body: nil)
        case .body(let body):
            try await api.editPullRequest(token: token, reference: reference, title: nil, body: body)
        case .fileViewed(let pullRequestID, let path, let viewed):
            try await api.setFileViewed(token: token, pullRequestID: pullRequestID, path: path, viewed: viewed)
        case .threadResolved(let threadID, let resolved):
            try await api.setReviewThreadResolved(token: token, threadID: threadID, resolved: resolved)
        case .reviewRequested(let name, let kind, let requested):
            try await api.setReviewRequested(token: token, reference: reference, name: name, kind: kind,
                                             requested: requested)
        case .comment(let comment, _):
            return .posted(commentID: try await api.postPullRequestComment(token: token, reference: reference,
                                                                           comment: comment))
        case .review(let review, _):
            return .posted(commentID: try await api.submitReview(token: token, reference: reference, review: review))
        case .startReview(let pullRequestID, let commitID, _):
            return .startedReview(id: try await api.startPendingReview(token: token, pullRequestID: pullRequestID,
                                                                       commitID: commitID))
        case .reviewComment(let comment, let review, _):
            let commentID = try await api.addPendingReviewComment(token: token, reviewID: try Self.reviewID(review),
                                                                  comment: comment)
            return commentID.map { .posted(commentID: $0) } ?? .sent
        case .submitPendingReview(let review, let event, let body, _):
            let reviewID = try await api.submitPendingReview(token: token, reviewID: try Self.reviewID(review),
                                                             event: event, body: body)
            return reviewID.map { .posted(commentID: $0) } ?? .sent
        case .discardPendingReview(let review):
            do {
                try await api.deletePendingReview(token: token, reviewID: try Self.reviewID(review))
            } catch let error as GraphQLError where error.isNotFound {
                // Already gone, such as when the app quit before GitHub's answer to the first try arrived.
            }
        }
        return .sent
    }

    /// The pending review's node ID. A change still waiting for the change that starts its review is only sent after
    /// that one, so the review didn't start.
    private static func reviewID(_ target: PendingChange.ReviewTarget) throws -> String {
        guard case .review(let id) = target else { throw PendingChange.ReviewNotStartedError() }
        return id
    }

    /// Whether a failed request may still have reached GitHub, such as when the connection dropped or timed out
    /// before the answer, or GitHub failed after taking it. GitHub never acts on a request it answered with a 4xx.
    static func mayHaveReachedGitHub(_ error: Error) -> Bool {
        if let statusCode = (error as? GitHubAPIError)?.statusCode ?? (error as? GraphQLError)?.statusCode {
            return statusCode >= 500
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotParseResponse, .badServerResponse].contains(error.code)
    }

    /// GitHub's error, or for a comment or review, what it means for it.
    @MainActor
    private static func failureMessage(for change: PendingChange, error: Error, cache: PullRequestDetailCache) -> String {
        let message = error.localizedDescription
        if error is PendingChange.ReviewNotStartedError, case .startedBy(let startID)? = change.kind.reviewTarget,
           let startError = cache.pendingChanges(for: change.reference).first(where: { $0.id == startID })?.error {
            return "\(message) \(startError)"
        }
        guard !change.kind.isSafeToResend else { return message }
        if mayHaveReachedGitHub(error) {
            return "\(message) GitHub may have \(change.kind.outcomeIfSent) anyway, so check before you retry."
        }
        guard case .comment(let comment, _) = change.kind else { return message }
        // GitHub refuses a comment on a commit that's no longer part of the pull request, such as after a force push.
        if case .inline(_, let commitID, _) = comment, (error as? GitHubAPIError)?.statusCode == 422,
           let headSHA = cache.entry(for: change.reference)?.content.detail.headSHA, headSHA != commitID {
            return "New commits were pushed after you wrote this comment, and GitHub no longer takes it on the "
                + "commit you wrote it on. Copy it and comment on the current diff."
        }
        return message
    }

    /// Loads again what GitHub changed, then drops the change in the same step as saving the new copy, so the view
    /// goes straight from the change to GitHub's copy of it. If that load fails, the change is kept in the old copy.
    private func confirm(_ change: PendingChange, session: UUID) async {
        // A new token dropped the change, so nothing is loaded for it with that token.
        let current = await MainActor.run { [cache, credential] in
            (session: credential()?.session, resources: Self.resources(changedBy: change, cache: cache))
        }
        guard current.session == session else { return }
        var isRefreshed = !current.resources.isEmpty
        for resource in current.resources {
            do {
                try await request(resource)
            } catch {
                isRefreshed = false
            }
        }
        await updateCache(session: session) { $0.confirm(change.id, applyingToEntry: !isRefreshed) }
        switch change.kind {
        case .title, .reviewRequested:
            // My PRs shows the title and who was asked to review.
            _ = try? await request(.openList)
        case .review, .submitPendingReview:
            // To Review drops a pull request once I've reviewed it.
            _ = try? await request(.reviewRequests)
        case .body, .fileViewed, .threadResolved, .comment, .startReview, .reviewComment, .discardPendingReview:
            break
        }
    }

    /// What GitHub changed: the detail, the comments (once they loaded), or both, for a review, whose verdict shows
    /// in the Reviewers list and its message in the Activity list.
    @MainActor
    private static func resources(changedBy change: PendingChange, cache: PullRequestDetailCache) -> [Resource] {
        let reference = change.reference
        var comments: [Resource] = []
        if let entry = cache.entry(for: reference), entry.comments != nil {
            comments = [.comments(reference, entry.commentLimits)]
        }
        switch change.kind {
        case .title, .body, .fileViewed, .reviewRequested:
            return [.detail(reference)]
        case .threadResolved, .comment, .startReview, .reviewComment, .discardPendingReview:
            return comments
        case .review, .submitPendingReview:
            return [.detail(reference)] + comments
        }
    }

    /// Runs `update` if the token hasn't changed since `session`, since the cache dropped that token's changes.
    @discardableResult
    private func updateCache(session: UUID, _ update: @escaping @MainActor (PullRequestDetailCache) -> Void) async -> Bool {
        await readCache(session: session, update) != nil
    }

    /// Like `updateCache`, returning what `read` returns, or nil when the token changed.
    private func readCache<T>(session: UUID, _ read: @escaping @MainActor (PullRequestDetailCache) -> T) async -> T? {
        await MainActor.run { [cache, credential] () -> T? in
            guard credential()?.session == session else { return nil }
            return read(cache)
        }
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
