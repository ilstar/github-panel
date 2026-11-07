import Foundation
import Combine

/// Pull request content loaded so far, so a pull request shows right away when it is opened again
/// or after a refresh loaded it in the background. Keeps the most recently used entries.
/// With a store, the entries are saved there and restored when the app starts again.
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

    let updates = PassthroughSubject<(PullRequestReference, Entry), Never>()

    let capacity: Int
    private var entries: [PullRequestReference: Entry] = [:]
    /// References from least to most recently used.
    private var order: [PullRequestReference] = []
    /// When each entry was last used, saved with it so the order survives a restart.
    private var lastUsedAt: [PullRequestReference: Date] = [:]
    private var lastUseTime = Date.distantPast

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

    func entry(for reference: PullRequestReference) -> Entry? {
        guard let entry = entries[reference] else { return nil }
        touch(reference)
        return entry
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
    func store(_ comments: PullRequestComments, for reference: PullRequestReference,
               limits: PullRequestCommentLimits = PullRequestCommentLimits()) {
        guard entries[reference] != nil else { return }
        entries[reference]?.comments = comments
        entries[reference]?.commentLimits = limits
        touch(reference)
        publish(reference)
    }

    func store(_ checks: PullRequestChecks, for reference: PullRequestReference, headSHA: String) {
        guard entries[reference]?.content.detail.headSHA == headSHA else { return }
        entries[reference]?.checks = checks
        touch(reference)
        publish(reference)
    }

    func storeChanges(_ files: [PullRequestFile], for reference: PullRequestReference,
                      baseSHA: String, headSHA: String) {
        guard let detail = entries[reference]?.content.detail,
              detail.lastReviewedSHA == baseSHA, detail.headSHA == headSHA else { return }
        entries[reference]?.filesSinceLastReview = files
        touch(reference)
        publish(reference)
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
    func removeAll() {
        entries = [:]
        order = []
        lastUsedAt = [:]
        changed = []
        used = []
        removed = []
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        saveTask?.cancel()
        saveTask = nil
        if let store {
            enqueueWrite { await store.removeAllPullRequestDetails() }
        }
    }

    /// Waits for the saved entries to load. Used by tests.
    func waitForRestore() async {
        await loadTask?.value
    }

    /// Writes the changes to the store now rather than after the save delay. Used by tests.
    func saveNow() async {
        saveTask?.cancel()
        saveTask = nil
        await writeSnapshot()
    }

    /// Loads the saved entries off the main thread. Entries stored meanwhile are newer, so they win.
    private func restoreFromStore() {
        guard let store else { return }
        let generation = generation
        loadTask = Task { [weak self] in
            let saved = await store.pullRequestDetails()
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.restore(saved)
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
        if let entry = entries[reference] { updates.send((reference, entry)) }
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
            await self.writeSnapshot()
        }
    }

    private func writeSnapshot() async {
        guard let store else { return }
        var changes = LocalStore.PullRequestDetailChanges(removed: Array(removed))
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
        await enqueueWrite { await store.savePullRequestDetails(changes) }.value
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
