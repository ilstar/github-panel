import Foundation
import Combine

/// Pull request content loaded so far, so a pull request shows right away when it is opened again
/// or after a refresh loaded it in the background. Keeps the most recently used entries.
/// Also holds the changes the user made that GitHub hasn't confirmed, which show on top of the entries.
/// With a store, the entries and changes are saved there and restored when the app starts again.
@MainActor
final class PullRequestDetailCache {
    struct Entry: Equatable, Codable {
        var content: PullRequestDetailContent
        /// Nil until the comments first load.
        var comments: PullRequestComments?
        var commentLimits = PullRequestCommentLimits()
        var checks: PullRequestChecks?
        var filesSinceLastReview: [PullRequestFile]?
    }

    /// The shown entry, with its pending changes applied, each time it or its changes change.
    let updates = PassthroughSubject<(PullRequestReference, Entry), Never>()

    let capacity: Int
    private var entries: [PullRequestReference: Entry] = [:]
    /// References from least to most recently used.
    private var order: [PullRequestReference] = []
    /// When each entry was last used, saved with it so the order survives a restart.
    private var lastUsedAt: [PullRequestReference: Date] = [:]
    private var lastUseTime = Date.distantPast
    /// Changes GitHub hasn't confirmed, oldest first.
    private var pending: [PendingChange] = []
    private var lastChangeTime = Date.distantPast

    private let store: LocalStore?
    private let saveDelay: TimeInterval
    private var saveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// The last write sent to the store. Each write waits for the one before it, so they land in order.
    private var writeTask: Task<Void, Never>?
    /// Entries stored, used, or evicted since the last save.
    private var changed: Set<PullRequestReference> = []
    private var used: Set<PullRequestReference> = []
    private var removed: Set<PullRequestReference> = []
    /// Bumped by `removeAll`, so a load or save started before it does not bring the old entries back.
    private var generation = 0

    init(capacity: Int = 100, store: LocalStore? = nil, saveDelay: TimeInterval = 1) {
        self.capacity = capacity
        self.store = store
        self.saveDelay = saveDelay
        restoreFromStore()
    }

    var count: Int { entries.count }

    /// The pull request as GitHub last returned it.
    func entry(for reference: PullRequestReference) -> Entry? {
        guard let entry = entries[reference] else { return nil }
        touch(reference)
        return entry
    }

    /// The pull request as the detail view shows it: as GitHub last returned it, with its pending and failed
    /// changes applied in order.
    func shownEntry(for reference: PullRequestReference) -> Entry? {
        entry(for: reference).map { PendingChange.apply(pendingChanges(for: reference), to: $0) }
    }

    /// Stores a pull request's detail and files, keeping any comments already cached for it.
    func store(_ content: PullRequestDetailContent) {
        let reference = content.detail.reference
        var entry = entries[reference] ?? Entry(content: content)
        if entry.content.detail.headSHA != content.detail.headSHA {
            entry.checks = nil
            entry.filesSinceLastReview = nil
        }
        if entry.content.detail.lastReviewedSHA != content.detail.lastReviewedSHA {
            entry.filesSinceLastReview = nil
        }
        entry.content = content
        entries[reference] = entry
        touch(reference)
        evictIfNeeded()
        publish(reference)
    }

    /// Stores a pull request's comments. Ignored until its detail is cached, since comments alone cannot be shown.
    /// Returns whether they were stored, as do the other stores below.
    @discardableResult
    func store(_ comments: PullRequestComments, for reference: PullRequestReference,
               limits: PullRequestCommentLimits = PullRequestCommentLimits()) -> Bool {
        guard entries[reference] != nil else { return false }
        entries[reference]?.comments = comments
        entries[reference]?.commentLimits = limits
        touch(reference)
        publish(reference)
        return true
    }

    @discardableResult
    func store(_ checks: PullRequestChecks, for reference: PullRequestReference, headSHA: String) -> Bool {
        guard entries[reference]?.content.detail.headSHA == headSHA else { return false }
        entries[reference]?.checks = checks
        touch(reference)
        publish(reference)
        return true
    }

    @discardableResult
    func storeChanges(_ files: [PullRequestFile], for reference: PullRequestReference,
                      baseSHA: String, headSHA: String) -> Bool {
        guard let detail = entries[reference]?.content.detail,
              detail.lastReviewedSHA == baseSHA, detail.headSHA == headSHA else { return false }
        entries[reference]?.filesSinceLastReview = files
        touch(reference)
        publish(reference)
        return true
    }

    /// Whether the cached copy is missing, incomplete, or older than the list's `updatedAt`.
    func needsRefresh(_ reference: PullRequestReference, updatedAt: Date) -> Bool {
        guard let entry = entries[reference],
              entry.comments != nil,
              entry.checks != nil,
              let cachedAt = entry.content.detail.updatedAt else { return true }
        return updatedAt > cachedAt
    }

    /// Empties the cache and deletes its saved entries, such as when the account changes.
    /// Pending changes go too: they were made as the old account, so they aren't sent with a new token.
    func removeAll() {
        entries = [:]
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

    func markSending(_ id: UUID) {
        update(id) { $0.state = .sending }
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

    func markFailed(_ id: UUID, error: String) {
        update(id) {
            $0.state = .failed
            $0.error = error
        }
    }

    /// Drops a change, so the pull request shows as GitHub last returned it.
    func discard(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let change = pending.remove(at: index)
        publishShown(change.reference)
        savePending([], removing: [id])
    }

    /// Drops a change GitHub accepted. The entry was refreshed after it, or, when that failed, gets the change
    /// applied, so it keeps showing until the next load. Saves the entry and deletes the change in one transaction.
    func confirm(_ id: UUID, applyingToEntry: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let change = pending.remove(at: index)
        let reference = change.reference
        if applyingToEntry, let entry = entries[reference] {
            entries[reference] = PendingChange.apply(change, to: entry)
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
        guard let entry = entries[reference] else { return }
        updates.send((reference, PendingChange.apply(pendingChanges(for: reference), to: entry)))
    }

    /// Waits for the saved entries to load. Used by tests.
    func waitForRestore() async {
        await loadTask?.value
    }

    /// Writes the changes to the store now rather than after the save delay. Used by tests.
    func saveNow() async {
        saveTask?.cancel()
        saveTask = nil
        await writeSnapshot()?.value
    }

    /// Loads the saved entries and changes off the main thread. Entries stored meanwhile are newer, so they win.
    private func restoreFromStore() {
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
        let restored = saved.filter { entries[$0.entry.content.detail.reference] == nil }
        guard !restored.isEmpty else { return }
        for saved in restored {
            let reference = saved.entry.content.detail.reference
            entries[reference] = saved.entry
            lastUsedAt[reference] = saved.lastUsedAt
        }
        // Saved entries were used before anything this run, so they go first in the order.
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
            guard let entry = entries[reference], let lastUsedAt = lastUsedAt[reference] else { continue }
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
        // Always later than the last use, so entries used in the same instant still restore in order.
        lastUseTime = max(Date(), lastUseTime.addingTimeInterval(0.000_001))
        lastUsedAt[reference] = lastUseTime
        used.insert(reference)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let reference = order.removeFirst()
            entries.removeValue(forKey: reference)
            lastUsedAt.removeValue(forKey: reference)
            changed.remove(reference)
            used.remove(reference)
            if store != nil { removed.insert(reference) }
        }
    }
}
