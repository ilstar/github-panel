import Foundation
import Combine

/// Reads and writes PRs in SQLite and publishes changes to the UI. This facade holds no PR rows or details:
/// the list view owns its visible page, and each open detail view owns the content it displays.
/// Pending edits stay overlaid until GitHub confirms them. Reads wait for earlier queued writes, so a newly
/// preloaded PR is available immediately without a separate memory cache or a network request.
@MainActor
final class PullRequestCache {
    struct ListState: Equatable {
        var fetchedAt: Date?
        var lastError: String?
        var isLoading = false
    }

    enum ListChange: Equatable {
        case loaded(PullRequestListKind)
        case changed(PullRequestListKind)
    }

    let listUpdates = PassthroughSubject<ListChange, Never>()
    let detailUpdates = PassthroughSubject<(PullRequestReference, PullRequestDetailEntry), Never>()
    var hiddenReviewRequests: [String: HiddenReviewRequest] = [:]
    var viewerLogin: String?
    private(set) var openSSOAuthorizationURL: URL?
    var reviewRequestsSSOAuthorizationURL: URL? { store.pullRequestListInfo(.reviewRequests)?.ssoAuthorizationURL }
    private var listStates: [PullRequestListKind: ListState] = [:]
    private var loads: [PullRequestListKind: Set<UUID>] = [:]
    private var pending: [PendingChange] = []
    private var lastChangeTime = Date.distantPast
    private let store: LocalStore
    private var loadTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var generation = 0

    init(store: LocalStore = .inMemory()) {
        self.store = store
        openSSOAuthorizationURL = store.pullRequestListInfo(.open)?.ssoAuthorizationURL
        restorePendingChanges()
    }

    // MARK: - Lists

    var open: [PullRequestRow]? { store.pullRequestLists(kinds: [.open]).open }
    var reviewRequests: ReviewRequests? { store.pullRequestLists(kinds: [.reviewRequests]).reviewRequests }

    func historyPage(_ page: Int) -> PullRequestHistoryPage? {
        store.pullRequestLists(kinds: [.history(page: page)]).historyPage(page)
    }

    func state(of kind: PullRequestListKind) -> ListState {
        var state = listStates[kind] ?? ListState()
        if state.fetchedAt == nil, holds(kind) {
            let page = store.pullRequestListInfo(kind)?.pagination?.request.page ?? 1
            let key = page > 1 ? "\(kind.key):page:\(page)" : kind.key
            state.fetchedAt = store.syncStateNow(for: key)?.fetchedAt
                ?? store.pullRequestListSavedAt(kind)
        }
        state.isLoading = !(loads[kind] ?? []).isEmpty
        return state
    }

    func holds(_ kind: PullRequestListKind) -> Bool { store.holdsPullRequestList(kind) }

    func store(_ result: OpenPullRequests, fetchedAt: Date, observedAt: Date? = nil) {
        viewerLogin = result.login
        openSSOAuthorizationURL = result.ssoAuthorizationURL
        let records = Dictionary(result.rows.map { row in
            (row.reference, PullRequestRecord(openRow: row, status: row.status(observedAt: observedAt ?? fetchedAt)))
        }, uniquingKeysWith: { first, _ in first })
        saveList(.open, members: result.rows.map { PullRequestListMember(reference: $0.reference) },
                 info: pageInfo(.open, pagination: result.pagination, sso: result.ssoAuthorizationURL, ids: result.rows.map(\.id)),
                 fetchedAt: fetchedAt, records: records)
    }

    func store(_ requests: ReviewRequests, fetchedAt: Date, observedAt: Date? = nil) {
        let members = ReviewRequestGroup.allCases.flatMap { group in
            requests.rows(in: group).map { PullRequestListMember(reference: $0.reference, reviewGroup: group) }
        }
        let records = Dictionary(requests.rows.map { row in
            (row.reference, PullRequestRecord(reviewRequestRow: row, status: row.status(observedAt: observedAt ?? fetchedAt)))
        }, uniquingKeysWith: { first, _ in first })
        saveList(.reviewRequests, members: members,
                 info: pageInfo(.reviewRequests, pagination: requests.pagination, sso: requests.ssoAuthorizationURL, ids: requests.rows.map(\.id)),
                 fetchedAt: fetchedAt, records: records)
    }

    func pagination(of kind: PullRequestListKind) -> PullRequestPagination? {
        store.pullRequestListInfo(kind)?.pagination
    }

    func pageRequest(_ page: Int, in kind: PullRequestListKind) -> PullRequestPageRequest? {
        store.pullRequestListInfo(kind)?.pageRequests?[page]
    }

    func page(containing id: String, in kind: PullRequestListKind) -> Int? {
        store.pullRequestListInfo(kind)?.pageIDs?.first { $0.value.contains(id) }?.key
    }

    private func pageInfo(_ kind: PullRequestListKind, pagination: PullRequestPagination?, sso: URL?, ids: [String]) -> PullRequestListInfo {
        guard let pagination else { return PullRequestListInfo(ssoAuthorizationURL: sso) }
        // Refreshing a boundary invalidates the pages after it. Earlier boundaries remain navigable.
        var requests = (store.pullRequestListInfo(kind)?.pageRequests ?? [:]).filter { $0.key <= pagination.request.page }
        requests[pagination.request.page] = pagination.request
        if let next = pagination.next { requests[next.page] = next }
        var pageIDs = (store.pullRequestListInfo(kind)?.pageIDs ?? [:]).filter { $0.key < pagination.request.page }
        let currentIDs = Set(ids)
        pageIDs = pageIDs.mapValues { $0.filter { !currentIDs.contains($0) } }
        pageIDs[pagination.request.page] = ids
        return PullRequestListInfo(ssoAuthorizationURL: sso, pagination: pagination, pageRequests: requests, pageIDs: pageIDs)
    }

    func store(_ page: PullRequestHistoryPage, asPage number: Int, fetchedAt: Date) {
        let records = Dictionary(page.rows.map { ($0.reference, PullRequestRecord(historyRow: $0)) },
                                 uniquingKeysWith: { first, _ in first })
        saveList(.history(page: number), members: page.rows.map { PullRequestListMember(reference: $0.reference) },
                 info: PullRequestListInfo(page: page.page, perPage: page.perPage, totalCount: page.totalCount),
                 fetchedAt: fetchedAt, records: records)
    }

    func removeOpenPullRequest(id: String) {
        guard let row = open?.first(where: { $0.id == id }) else { return }
        store.removeOpenPullRequest(row.reference)
        listUpdates.send(.changed(.open))
    }

    func showError(_ message: String, on kind: PullRequestListKind) {
        listStates[kind, default: ListState()].lastError = message
        listUpdates.send(.changed(kind))
    }

    func startLoading(_ kind: PullRequestListKind, id: UUID) {
        loads[kind, default: []].insert(id)
        listStates[kind, default: ListState()].lastError = nil
        listUpdates.send(.changed(kind))
    }

    func stopLoading(_ kind: PullRequestListKind, id: UUID) {
        guard loads[kind]?.remove(id) != nil else { return }
        listUpdates.send(.changed(kind))
    }

    func stopAllLoading() {
        let kinds = loads.filter { !$0.value.isEmpty }.keys
        loads = [:]
        for kind in kinds { listUpdates.send(.changed(kind)) }
    }

    func removeLists() {
        viewerLogin = nil
        openSSOAuthorizationURL = nil
        listStates = [:]
        loads = [:]
        store.removePullRequestLists()
    }

    private func saveList(_ kind: PullRequestListKind, members: [PullRequestListMember], info: PullRequestListInfo,
                          fetchedAt: Date, records: [PullRequestReference: PullRequestRecord]) {
        store.savePullRequestList(.init(savedAt: fetchedAt, info: info, members: members), as: kind, records: records)
        listStates[kind, default: ListState()].fetchedAt = fetchedAt
        listStates[kind]?.lastError = nil
        listUpdates.send(.loaded(kind))
        for other in store.listKinds(overlapping: kind) {
            listUpdates.send(.changed(other))
        }
    }

    private func observe(_ status: PullRequestStatus, for reference: PullRequestReference) {
        store.savePullRequestStatus(status, for: reference)
        for kind in store.listKinds(containing: reference) { listUpdates.send(.changed(kind)) }
    }

    // MARK: - Details

    var detailCount: Int { store.pullRequestDetailCount }

    func entry(for reference: PullRequestReference) -> PullRequestDetailEntry? {
        store.pullRequestDetail(reference)
    }

    func shownEntry(for reference: PullRequestReference) -> PullRequestDetailEntry? {
        entry(for: reference).map { PendingChange.apply(pendingChanges(for: reference), to: $0) }
    }

    func store(_ content: PullRequestDetailContent, sentAt: Date? = nil) {
        let reference = content.detail.reference
        var entry = entry(for: reference) ?? PullRequestDetailEntry(content: content)
        if entry.content.detail.headSHA != content.detail.headSHA {
            entry.checks = nil
            entry.filesSinceLastReview = nil
        }
        if entry.content.detail.lastReviewedSHA != content.detail.lastReviewedSHA { entry.filesSinceLastReview = nil }
        entry.content = content
        save(entry, for: reference)
        if let sentAt {
            observe(PullRequestStatus(headSHA: content.detail.headSHA, checkState: nil, observedAt: sentAt), for: reference)
        }
    }

    @discardableResult
    func store(_ comments: PullRequestComments, for reference: PullRequestReference,
               limits: PullRequestCommentLimits = PullRequestCommentLimits()) -> Bool {
        guard var entry = entry(for: reference) else { return false }
        entry.comments = comments
        entry.commentLimits = limits
        save(entry, for: reference)
        return true
    }

    @discardableResult
    func store(_ checks: PullRequestChecks, for reference: PullRequestReference, headSHA: String,
               sentAt: Date? = nil) -> Bool {
        guard var entry = entry(for: reference), entry.content.detail.headSHA == headSHA else { return false }
        entry.checks = checks
        save(entry, for: reference)
        if let sentAt {
            observe(PullRequestStatus(headSHA: headSHA, checkState: checks.checkState, observedAt: sentAt), for: reference)
        }
        return true
    }

    @discardableResult
    func storeChanges(_ files: [PullRequestFile], for reference: PullRequestReference,
                      baseSHA: String, headSHA: String) -> Bool {
        guard var entry = entry(for: reference), entry.content.detail.lastReviewedSHA == baseSHA,
              entry.content.detail.headSHA == headSHA else { return false }
        entry.filesSinceLastReview = files
        save(entry, for: reference)
        return true
    }

    func needsRefresh(_ reference: PullRequestReference, updatedAt: Date) -> Bool {
        guard let entry = entry(for: reference), entry.comments != nil, entry.checks != nil,
              let cachedAt = entry.content.detail.updatedAt else { return true }
        return updatedAt > cachedAt
    }

    private func save(_ entry: PullRequestDetailEntry, for reference: PullRequestReference) {
        writeTask = store.enqueuePullRequestDetails(.init(saved: [.init(entry: entry, lastUsedAt: Date())]))
        // Publish the value already in hand. Only open views subscribe; the facade retains no copy.
        detailUpdates.send((reference, PendingChange.apply(pendingChanges(for: reference), to: entry)))
    }

    func removeDetails() {
        pending = []
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        writeTask = store.enqueueRemoveDetailsAndChanges()
    }

    // MARK: - Pending changes

    func pendingChanges(for reference: PullRequestReference) -> [PendingChange] {
        pending.filter { $0.reference == reference }
    }

    /// Pull requests with changes waiting to be sent.
    var referencesWithChangesToSend: [PullRequestReference] {
        var references: [PullRequestReference] = []
        for change in pending where change.state == .pending && !references.contains(change.reference) {
            references.append(change.reference)
        }
        return references
    }

    /// The pull request's oldest change waiting to be sent. Failed ones wait for Retry.
    func nextChangeToSend(for reference: PullRequestReference) -> PendingChange? {
        pending.first { $0.reference == reference && $0.state == .pending }
    }

    /// Adds a change, which shows right away. It replaces an earlier change to the same field that hasn't started
    /// sending, or that failed, since this one sets the field again. A comment replaces nothing.
    @discardableResult
    func add(_ kind: PendingChange.Kind, to reference: PullRequestReference) -> PendingChange {
        // Always later than the last change, so changes made in the same instant still send in order.
        lastChangeTime = max(Date(), lastChangeTime.addingTimeInterval(0.000_001))
        let change = PendingChange(reference: reference, kind: kind, createdAt: lastChangeTime)
        let replaced = kind.field.map { field in
            pending.filter { $0.reference == reference && $0.kind.field == field && $0.state != .sending }.map(\.id)
        } ?? []
        pending.removeAll { replaced.contains($0.id) }
        pending.append(change)
        publishShown(reference)
        savePending([change], removing: replaced)
        return change
    }

    /// Returns false when the change is gone, such as after a Discard, so it isn't sent.
    @discardableResult
    func markSending(_ id: UUID) -> Bool {
        guard pending.contains(where: { $0.id == id }) else { return false }
        update(id) { $0.state = .sending }
        return true
    }

    /// Puts a failed change back in line, for Retry.
    func markPending(_ id: UUID) {
        update(id) {
            $0.state = .pending
            $0.error = nil
        }
    }

    /// Notes the comment GitHub posted for a change, so GitHub's copy of it shows instead once it loads. Saved, so a
    /// restart before the confirm doesn't offer to post it again.
    func markPosted(_ id: UUID, commentID: Int) {
        update(id) { $0.postedCommentID = commentID }
    }

    /// Notes the pending review GitHub started for a `startReview` change, and sends the changes waiting for it to
    /// that review. Saved together, so a restart never leaves a change waiting for a review that already started.
    func markStarted(_ id: UUID, reviewID: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }),
              case .startReview(let pullRequestID, let commitID, _) = pending[index].kind else { return }
        pending[index].kind = .startReview(pullRequestID: pullRequestID, commitID: commitID, reviewID: reviewID)
        let dependents = sendToReview(reviewID, changesStartedBy: id)
        publishShown(pending[index].reference)
        savePending([pending[index]] + dependents)
    }

    /// Sends the changes waiting for the `startReview` change `startID` to the pending review `reviewID` instead, and
    /// drops that change, such as when GitHub already has a review the failed start may have made.
    func useReview(_ reviewID: String, forChangesStartedBy startID: UUID) {
        guard let start = pending.first(where: { $0.id == startID }) else { return }
        let dependents = sendToReview(reviewID, changesStartedBy: startID)
        pending.removeAll { $0.id == startID }
        publishShown(start.reference)
        savePending(dependents, removing: [startID])
    }

    /// The changes waiting for the `startReview` change `startID`, oldest first.
    func changes(startedBy startID: UUID) -> [PendingChange] {
        pending.filter { $0.kind.reviewTarget == .startedBy(startID) }
    }

    private func sendToReview(_ reviewID: String, changesStartedBy startID: UUID) -> [PendingChange] {
        var dependents: [PendingChange] = []
        for index in pending.indices where pending[index].kind.reviewTarget == .startedBy(startID) {
            pending[index].kind = pending[index].kind.sending(toReview: reviewID)
            dependents.append(pending[index])
        }
        return dependents
    }

    func markFailed(_ id: UUID, error: String) {
        update(id) {
            $0.state = .failed
            $0.error = error
        }
    }

    /// Drops a change, so the pull request shows as GitHub last returned it. Dropping the last change waiting for a
    /// pending review that GitHub hasn't started, and isn't starting now, drops the change that would start it too.
    func discard(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let change = pending.remove(at: index)
        var removed = [id]
        if case .startedBy(let startID)? = change.kind.reviewTarget, changes(startedBy: startID).isEmpty,
           let start = pending.first(where: { $0.id == startID }), start.state != .sending {
            pending.removeAll { $0.id == startID }
            removed.append(startID)
        }
        publishShown(change.reference)
        savePending([], removing: removed)
    }

    /// Drops a `startReview` change and every change waiting for it, such as a pending review discarded before
    /// GitHub was asked to start it.
    func discardReview(startedBy startID: UUID) {
        guard let start = pending.first(where: { $0.id == startID }) else { return }
        let removed = [startID] + changes(startedBy: startID).map(\.id)
        pending.removeAll { removed.contains($0.id) }
        publishShown(start.reference)
        savePending([], removing: removed)
    }

    /// Drops a change GitHub accepted. The detail was refreshed after it, or, when that failed, gets the change
    /// applied, so it keeps showing until the next load. Saves the detail and deletes the change in one transaction.
    func confirm(_ id: UUID, applyingToEntry: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let change = pending.remove(at: index)
        let reference = change.reference
        let entry = entry(for: reference).map { applyingToEntry ? PendingChange.apply(change, to: $0) : $0 }
        let saved = entry.map { [LocalStore.SavedPullRequestDetail(entry: $0, lastUsedAt: Date())] } ?? []
        writeTask = store.enqueuePullRequestDetails(.init(saved: saved, confirmed: [id]))
        publishShown(reference)
    }

    private func update(_ id: UUID, _ change: (inout PendingChange) -> Void) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        change(&pending[index])
        publishShown(pending[index].reference)
        savePending([pending[index]])
    }

    /// Changes are saved right away rather than after the save delay, so they survive the app quitting.
    private func savePending(_ changes: [PendingChange], removing removed: [UUID] = []) {
        writeTask = store.enqueuePendingChanges(changes, removing: removed)
    }

    private func publishShown(_ reference: PullRequestReference) {
        guard let entry = entry(for: reference) else { return }
        detailUpdates.send((reference, PendingChange.apply(pendingChanges(for: reference), to: entry)))
    }

    /// Waits for pending changes from the last session; PR details are read individually on demand.
    func waitForRestore() async { await loadTask?.value }

    /// Writes are queued immediately. Tests can wait for the most recent write to complete.
    func saveNow() async { await writeTask?.value }

    private func restorePendingChanges() {
        let generation = generation
        loadTask = Task { [weak self, store] in
            let changes = await store.pendingChanges()
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            let ids = Set(self.pending.map(\.id))
            self.pending = changes.filter { !ids.contains($0.id) } + self.pending
            self.lastChangeTime = max(self.lastChangeTime, changes.last?.createdAt ?? .distantPast)
            for reference in Set(changes.map(\.reference)) { self.publishShown(reference) }
        }
    }
}
