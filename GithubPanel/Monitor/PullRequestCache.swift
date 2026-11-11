import Foundation
import Combine

/// Everything loaded so far about pull requests, one record per pull request, as the `pull_request` table saves it:
/// the row each list returned, the newest status any load saw, and the detail once it loads. The sync engine fills it,
/// `PRMonitor` shows the lists, and the detail windows show the details.
///
/// Every list holding a pull request shows the same status, so a detail or checks load newer than the list updates
/// its row. The details keep the most recently used ones. It also holds the changes the user made that GitHub hasn't
/// confirmed, which show on top of the details.
///
/// With a store, records, lists and changes are saved there and restored when the app starts again. Lists restore
/// right away, and when they last loaded comes from `sync_state`. Details restore in the background.
@MainActor
final class PullRequestCache {
    struct ListState: Equatable {
        /// When GitHub last returned the list.
        var fetchedAt: Date?
        var lastError: String?
        var isLoading = false
    }

    enum ListChange: Equatable {
        /// GitHub returned the list.
        case loaded(PullRequestListKind)
        /// Its rows changed some other way, or it started or stopped loading, or failed.
        case changed(PullRequestListKind)
    }

    /// A list's rows or state changed.
    let listUpdates = PassthroughSubject<ListChange, Never>()
    /// The shown detail, with its pending changes applied, each time it or its changes change.
    let detailUpdates = PassthroughSubject<(PullRequestReference, PullRequestDetailEntry), Never>()

    /// How many details are kept.
    let capacity: Int
    /// The token's login, from My PRs or the engine's lookup, so the viewer's unsent comments show as theirs. Not saved.
    var viewerLogin: String?
    /// Set when the last My PRs load left some out because the token isn't SSO-authorized. Not saved.
    private(set) var openSSOAuthorizationURL: URL?
    /// The pull requests a list holds or whose detail is kept.
    private(set) var records: [PullRequestReference: PullRequestRecord] = [:]

    // MARK: Lists

    /// Each loaded list, in order.
    private var members: [PullRequestListKind: [PullRequestListMember]] = [:]
    private var infos: [PullRequestListKind: PullRequestListInfo] = [:]
    private var listStates: [PullRequestListKind: ListState] = [:]
    /// The loads running for each list. A list is loading while it has any.
    private var loads: [PullRequestListKind: Set<UUID>] = [:]

    // MARK: Details

    /// Pull requests with a detail, from least to most recently used.
    private var order: [PullRequestReference] = []
    /// When each detail was last used, saved with it so the order survives a restart.
    private var lastUsedAt: [PullRequestReference: Date] = [:]
    private var lastUseTime = Date.distantPast
    /// Changes GitHub hasn't confirmed, oldest first.
    private var pending: [PendingChange] = []
    private var lastChangeTime = Date.distantPast

    private let store: LocalStore?
    private let saveDelay: TimeInterval
    private var saveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// The last detail write sent to the store. Each write waits for the one before it, so they land in order.
    private var writeTask: Task<Void, Never>?
    /// Details stored, used, or evicted since the last save.
    private var changed: Set<PullRequestReference> = []
    private var used: Set<PullRequestReference> = []
    private var removed: Set<PullRequestReference> = []
    /// Bumped by `removeDetails`, so a load or save started before it does not bring the old details back.
    private var generation = 0

    init(capacity: Int = 100, store: LocalStore? = nil, saveDelay: TimeInterval = 1) {
        self.capacity = capacity
        self.store = store
        self.saveDelay = saveDelay
        restoreListsFromStore()
        restoreDetailsFromStore()
    }

    // MARK: - Lists

    /// The lists as this cache holds them. The lists on screen show the saved ones instead; see `PRMonitor`.
    var open: [PullRequestRow]? {
        PullRequestListRows.open(members[.open], records: records)
    }

    var reviewRequests: ReviewRequests? {
        PullRequestListRows.reviewRequests(members[.reviewRequests], info: infos[.reviewRequests], records: records)
    }

    func historyPage(_ page: Int) -> PullRequestHistoryPage? {
        PullRequestListRows.historyPage(page, members: members[.history(page: page)],
                                        info: infos[.history(page: page)], records: records)
    }

    func state(of kind: PullRequestListKind) -> ListState {
        var state = listStates[kind] ?? ListState()
        state.isLoading = !(loads[kind] ?? []).isEmpty
        return state
    }

    /// Whether the list has loaded, so a fresh `sync_state` still counts.
    func holds(_ kind: PullRequestListKind) -> Bool {
        members[kind] != nil
    }

    /// Saves My PRs. `observedAt` is when the request was sent, which orders it against other loads' statuses.
    func store(_ result: OpenPullRequests, fetchedAt: Date, observedAt: Date? = nil) {
        viewerLogin = result.login
        openSSOAuthorizationURL = result.ssoAuthorizationURL
        let observedAt = observedAt ?? fetchedAt
        saveList(.open, members: result.rows.map { PullRequestListMember(reference: $0.reference) },
                 info: PullRequestListInfo(ssoAuthorizationURL: result.ssoAuthorizationURL), fetchedAt: fetchedAt) {
            for row in result.rows {
                self.records[row.reference, default: PullRequestRecord()].openRow = row
                self.records[row.reference]?.observe(row.status(observedAt: observedAt))
            }
        }
    }

    func store(_ requests: ReviewRequests, fetchedAt: Date, observedAt: Date? = nil) {
        let observedAt = observedAt ?? fetchedAt
        let members = ReviewRequestGroup.allCases.flatMap { group in
            requests.rows(in: group).map { PullRequestListMember(reference: $0.reference, reviewGroup: group) }
        }
        saveList(.reviewRequests, members: members,
                 info: PullRequestListInfo(ssoAuthorizationURL: requests.ssoAuthorizationURL), fetchedAt: fetchedAt) {
            for row in requests.rows {
                self.records[row.reference, default: PullRequestRecord()].reviewRequestRow = row
                if let status = row.status(observedAt: observedAt) { self.records[row.reference]?.observe(status) }
            }
        }
    }

    func store(_ page: PullRequestHistoryPage, asPage number: Int, fetchedAt: Date) {
        saveList(.history(page: number), members: page.rows.map { PullRequestListMember(reference: $0.reference) },
                 info: PullRequestListInfo(page: page.page, perPage: page.perPage, totalCount: page.totalCount),
                 fetchedAt: fetchedAt) {
            for row in page.rows {
                self.records[row.reference, default: PullRequestRecord()].historyRow = row
            }
        }
    }

    /// Takes a merged pull request off My PRs until the next load.
    func removeOpenPullRequest(id: String) {
        guard let rows = members[.open],
              let member = rows.first(where: { records[$0.reference]?.openRow?.id == id }) else { return }
        members[.open] = rows.filter { $0 != member }
        dropRecordIfUnused(member.reference)
        if let fetchedAt = listStates[.open]?.fetchedAt { saveListToStore(.open, savedAt: fetchedAt) }
        listUpdates.send(.changed(.open))
    }

    /// Shows an error above the list until it loads again, such as a failed load or a failed merge from a row.
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

    /// Forgets the running loads, such as when the token changes. Their results are dropped.
    func stopAllLoading() {
        let kinds = loads.filter { !$0.value.isEmpty }.keys
        loads = [:]
        for kind in kinds { listUpdates.send(.changed(kind)) }
    }

    /// Empties the lists and deletes the saved ones, such as when the token is removed. Details stay until
    /// `removeDetails`.
    func removeLists() {
        viewerLogin = nil
        openSSOAuthorizationURL = nil
        members = [:]
        infos = [:]
        listStates = [:]
        loads = [:]
        for reference in Array(records.keys) {
            records[reference]?.openRow = nil
            records[reference]?.reviewRequestRow = nil
            records[reference]?.historyRow = nil
            records[reference]?.status = nil
            dropRecordIfUnused(reference)
        }
        store?.removePullRequestLists()
    }

    /// Replaces a list, updating its pull requests' records with `update`, and drops records nothing needs anymore.
    private func saveList(_ kind: PullRequestListKind, members: [PullRequestListMember], info: PullRequestListInfo,
                          fetchedAt: Date, update: () -> Void) {
        update()
        let previous = self.members[kind] ?? []
        self.members[kind] = members
        infos[kind] = info
        for member in previous { dropRecordIfUnused(member.reference) }
        listStates[kind, default: ListState()].fetchedAt = fetchedAt
        listStates[kind]?.lastError = nil
        saveListToStore(kind, savedAt: fetchedAt)
        listUpdates.send(.loaded(kind))
        // Another list showing the same pull requests shows their new status too.
        let references = Set(members.map(\.reference))
        sendListChanges(for: references, except: kind)
    }

    private func saveListToStore(_ kind: PullRequestListKind, savedAt: Date) {
        guard let store, let members = members[kind], let info = infos[kind] else { return }
        let held = Dictionary(members.compactMap { member in records[member.reference].map { (member.reference, $0) } },
                              uniquingKeysWith: { first, _ in first })
        store.savePullRequestList(LocalStore.SavedPullRequestList(savedAt: savedAt, info: info, members: members),
                                  as: kind, records: held)
    }

    private func sendListChanges(for references: Set<PullRequestReference>, except excluded: PullRequestListKind? = nil) {
        for (kind, members) in members where kind != excluded
            && members.contains(where: { references.contains($0.reference) }) {
            listUpdates.send(.changed(kind))
        }
    }

    private func isListed(_ reference: PullRequestReference) -> Bool {
        members.values.contains { $0.contains { $0.reference == reference } }
    }

    /// Drops a record that no list holds and that has no detail.
    private func dropRecordIfUnused(_ reference: PullRequestReference) {
        guard let record = records[reference], record.detail == nil, !isListed(reference) else { return }
        records[reference] = nil
    }

    /// Notes the head commit and checks a detail or checks load sent at `sentAt` saw. Every list holding the pull
    /// request shows it if it's newer than what they last loaded.
    private func observe(_ status: PullRequestStatus, for reference: PullRequestReference) {
        guard var record = records[reference] else { return }
        let before = record.status
        record.observe(status)
        records[reference] = record
        guard record.status != before, let status = record.status else { return }
        store?.savePullRequestStatus(status, for: reference)
        sendListChanges(for: [reference])
    }

    private func restoreListsFromStore() {
        guard let store else { return }
        let saved = store.pullRequestLists()
        records = saved.records
        for (kind, list) in saved.lists {
            members[kind] = list.members
            infos[kind] = list.info
            listStates[kind] = ListState(fetchedAt: savedFetchedAt(for: kind, savedAt: list.savedAt))
        }
    }

    /// When the saved list last loaded, from `sync_state`. A token change clears that, so it falls back to when
    /// the list was saved.
    private func savedFetchedAt(for kind: PullRequestListKind, savedAt: Date) -> Date {
        store?.syncStateNow(for: kind.key)?.fetchedAt ?? savedAt
    }

    // MARK: - Details

    /// How many details are kept.
    var detailCount: Int { order.count }

    /// The pull request's detail as GitHub last returned it.
    func entry(for reference: PullRequestReference) -> PullRequestDetailEntry? {
        guard let entry = records[reference]?.detail else { return nil }
        touch(reference)
        return entry
    }

    /// The pull request's detail as the detail view shows it: as GitHub last returned it, with its pending and
    /// failed changes applied in order.
    func shownEntry(for reference: PullRequestReference) -> PullRequestDetailEntry? {
        entry(for: reference).map { PendingChange.apply(pendingChanges(for: reference), to: $0) }
    }

    /// Stores a pull request's detail and files, keeping any comments already cached for it. With `sentAt`, when the
    /// request that loaded it was sent, the lists show its head commit too if it's newer than theirs.
    func store(_ content: PullRequestDetailContent, sentAt: Date? = nil) {
        let reference = content.detail.reference
        var entry = records[reference]?.detail ?? PullRequestDetailEntry(content: content)
        if entry.content.detail.headSHA != content.detail.headSHA {
            entry.checks = nil
            entry.filesSinceLastReview = nil
        }
        if entry.content.detail.lastReviewedSHA != content.detail.lastReviewedSHA {
            entry.filesSinceLastReview = nil
        }
        entry.content = content
        records[reference, default: PullRequestRecord()].detail = entry
        touch(reference)
        evictIfNeeded()
        publish(reference)
        if let sentAt, records[reference] != nil {
            // A new head shows in the lists right away, with its checks pending until they load.
            observe(PullRequestStatus(headSHA: content.detail.headSHA, checkState: nil, observedAt: sentAt),
                    for: reference)
        }
    }

    /// Stores a pull request's comments. Ignored until its detail is cached, since comments alone cannot be shown.
    /// Returns whether they were stored, as do the other stores below.
    @discardableResult
    func store(_ comments: PullRequestComments, for reference: PullRequestReference,
               limits: PullRequestCommentLimits = PullRequestCommentLimits()) -> Bool {
        guard records[reference]?.detail != nil else { return false }
        records[reference]?.detail?.comments = comments
        records[reference]?.detail?.commentLimits = limits
        touch(reference)
        publish(reference)
        return true
    }

    /// Stores the checks on `headSHA`, ignored unless it's still the detail's head. With `sentAt`, the lists show
    /// what they add up to if it's newer than theirs.
    @discardableResult
    func store(_ checks: PullRequestChecks, for reference: PullRequestReference, headSHA: String,
               sentAt: Date? = nil) -> Bool {
        guard records[reference]?.detail?.content.detail.headSHA == headSHA else { return false }
        records[reference]?.detail?.checks = checks
        touch(reference)
        publish(reference)
        if let sentAt {
            observe(PullRequestStatus(headSHA: headSHA, checkState: checks.checkState, observedAt: sentAt),
                    for: reference)
        }
        return true
    }

    @discardableResult
    func storeChanges(_ files: [PullRequestFile], for reference: PullRequestReference,
                      baseSHA: String, headSHA: String) -> Bool {
        guard let detail = records[reference]?.detail?.content.detail,
              detail.lastReviewedSHA == baseSHA, detail.headSHA == headSHA else { return false }
        records[reference]?.detail?.filesSinceLastReview = files
        touch(reference)
        publish(reference)
        return true
    }

    /// Whether the cached detail is missing, incomplete, or older than the list's `updatedAt`.
    func needsRefresh(_ reference: PullRequestReference, updatedAt: Date) -> Bool {
        guard let entry = records[reference]?.detail,
              entry.comments != nil,
              entry.checks != nil,
              let cachedAt = entry.content.detail.updatedAt else { return true }
        return updatedAt > cachedAt
    }

    /// Empties the details and deletes the saved ones, such as when the account changes. Lists stay until
    /// `removeLists`. Pending changes go too: they were made as the old account, so they aren't sent with a new token.
    func removeDetails() {
        for reference in order {
            records[reference]?.detail = nil
            dropRecordIfUnused(reference)
        }
        order = []
        lastUsedAt = [:]
        changed = []
        used = []
        removed = []
        pending = []
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        saveTask?.cancel()
        saveTask = nil
        if let store {
            enqueueWrite {
                await store.removeAllPullRequestDetails()
                await store.removeAllPendingChanges()
            }
        }
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
        if applyingToEntry, let entry = records[reference]?.detail {
            records[reference]?.detail = PendingChange.apply(change, to: entry)
            changed.insert(reference)
            removed.remove(reference)
        }
        publishShown(reference)
        saveTask?.cancel()
        saveTask = nil
        writeSnapshot(confirming: [id])
    }

    private func update(_ id: UUID, _ change: (inout PendingChange) -> Void) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        change(&pending[index])
        publishShown(pending[index].reference)
        savePending([pending[index]])
    }

    /// Changes are saved right away rather than after the save delay, so they survive the app quitting.
    private func savePending(_ changes: [PendingChange], removing removed: [UUID] = []) {
        guard let store else { return }
        enqueueWrite { await store.savePendingChanges(changes, removing: removed) }
    }

    private func publishShown(_ reference: PullRequestReference) {
        guard let entry = records[reference]?.detail else { return }
        detailUpdates.send((reference, PendingChange.apply(pendingChanges(for: reference), to: entry)))
    }

    // MARK: - Saving details

    /// Waits for the saved details to load. Used by tests.
    func waitForRestore() async {
        await loadTask?.value
    }

    /// Writes the details to the store now rather than after the save delay. Used by tests.
    func saveNow() async {
        saveTask?.cancel()
        saveTask = nil
        await writeSnapshot()?.value
    }

    /// Loads the saved details and changes off the main thread. Details stored meanwhile are newer, so they win.
    private func restoreDetailsFromStore() {
        guard let store else { return }
        let generation = generation
        loadTask = Task { [weak self] in
            let changes = await store.pendingChanges()
            let saved = await store.pullRequestDetails()
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.restore(changes)
            self.restore(saved)
        }
    }

    private func restore(_ changes: [PendingChange]) {
        let ids = Set(pending.map(\.id))
        // Changes saved by the last run were made before any this run.
        pending = changes.filter { !ids.contains($0.id) } + pending
        lastChangeTime = max(lastChangeTime, changes.last?.createdAt ?? .distantPast)
        for reference in Set(changes.map(\.reference)) {
            publishShown(reference)
        }
    }

    private func restore(_ saved: [LocalStore.SavedPullRequestDetail]) {
        let restored = saved.filter { records[$0.entry.content.detail.reference]?.detail == nil }
        guard !restored.isEmpty else { return }
        for saved in restored {
            let reference = saved.entry.content.detail.reference
            records[reference, default: PullRequestRecord()].detail = saved.entry
            lastUsedAt[reference] = saved.lastUsedAt
        }
        // Saved details were used before anything this run, so they go first in the order.
        order = restored.map(\.entry.content.detail.reference) + order
        evictIfNeeded()
        for saved in restored {
            publish(saved.entry.content.detail.reference, save: false)
        }
    }

    private func publish(_ reference: PullRequestReference, save: Bool = true) {
        publishShown(reference)
        if save {
            changed.insert(reference)
            removed.remove(reference)
            scheduleSave()
        }
    }

    /// Saves once after a burst of changes, such as a background refresh storing many pull requests.
    private func scheduleSave() {
        guard store != nil, saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            await self.writeSnapshot()?.value
        }
    }

    /// Queues a write of what changed since the last one, deleting the `confirmed` pending changes with it.
    @discardableResult
    private func writeSnapshot(confirming confirmed: [UUID] = []) -> Task<Void, Never>? {
        guard let store else { return nil }
        var changes = LocalStore.PullRequestDetailChanges(removed: Array(removed), confirmed: confirmed)
        for reference in changed {
            guard let entry = records[reference]?.detail, let lastUsedAt = lastUsedAt[reference] else { continue }
            changes.saved.append(LocalStore.SavedPullRequestDetail(entry: entry, lastUsedAt: lastUsedAt))
        }
        for reference in used.subtracting(changed) {
            changes.used[reference] = lastUsedAt[reference]
        }
        changed = []
        used = []
        removed = []
        return enqueueWrite { await store.savePullRequestDetails(changes) }
    }

    @discardableResult
    private func enqueueWrite(_ write: @escaping () async -> Void) -> Task<Void, Never> {
        let previous = writeTask
        let task = Task {
            await previous?.value
            await write()
        }
        writeTask = task
        return task
    }

    private func touch(_ reference: PullRequestReference) {
        order.removeAll { $0 == reference }
        order.append(reference)
        // Always later than the last use, so details used in the same instant still restore in order.
        lastUseTime = max(Date(), lastUseTime.addingTimeInterval(0.000_001))
        lastUsedAt[reference] = lastUseTime
        used.insert(reference)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let reference = order.removeFirst()
            records[reference]?.detail = nil
            dropRecordIfUnused(reference)
            lastUsedAt.removeValue(forKey: reference)
            changed.remove(reference)
            used.remove(reference)
            if store != nil { removed.insert(reference) }
        }
    }
}
