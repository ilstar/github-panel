import Foundation
import Combine

/// Pull request content loaded so far, so a pull request shows right away when it is opened again
/// or after a refresh loaded it in the background. Keeps the most recently used entries.
/// With a file, the entries are saved there and restored when the app starts again.
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

    private let file: PullRequestDetailCacheFile?
    private let saveDelay: TimeInterval
    private var saveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// Bumped by `removeAll`, so a load or save started before it does not bring the old entries back.
    private var generation = 0

    init(capacity: Int = 100, fileURL: URL? = nil, saveDelay: TimeInterval = 1) {
        self.capacity = capacity
        self.file = fileURL.map(PullRequestDetailCacheFile.init(url:))
        self.saveDelay = saveDelay
        restoreFromFile()
    }

    /// Where the app keeps the cache: a file in its Caches folder, since everything in it can be loaded again.
    static var defaultFileURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = Bundle.main.bundleIdentifier ?? "GithubPanel"
        return caches.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("PullRequestDetails.json")
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

    /// Empties the cache and deletes its file, such as when the account changes.
    func removeAll() {
        entries = [:]
        order = []
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        saveTask?.cancel()
        saveTask = nil
        if let file {
            Task { await file.delete() }
        }
    }

    /// Waits for the saved entries to load. Used by tests.
    func waitForRestore() async {
        await loadTask?.value
    }

    /// Writes the entries to the file now rather than after the save delay. Used by tests.
    func saveNow() async {
        saveTask?.cancel()
        saveTask = nil
        await writeSnapshot()
    }

    /// Loads the saved entries off the main thread. Entries stored meanwhile are newer, so they win.
    private func restoreFromFile() {
        guard let file else { return }
        let generation = generation
        loadTask = Task { [weak self] in
            let saved = await file.load()
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.restore(saved)
        }
    }

    private func restore(_ saved: [Entry]) {
        let restored = saved.filter { entries[$0.content.detail.reference] == nil }
        guard !restored.isEmpty else { return }
        for entry in restored {
            entries[entry.content.detail.reference] = entry
        }
        // Saved entries were used before anything this run, so they go first in the order.
        order = restored.map(\.content.detail.reference) + order
        evictIfNeeded()
        for entry in restored {
            publish(entry.content.detail.reference, save: false)
        }
    }

    private func publish(_ reference: PullRequestReference, save: Bool = true) {
        if let entry = entries[reference] { updates.send((reference, entry)) }
        if save { scheduleSave() }
    }

    /// Saves once after a burst of changes, such as a background refresh storing many pull requests.
    private func scheduleSave() {
        guard file != nil, saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            await self.writeSnapshot()
        }
    }

    private func writeSnapshot() async {
        guard let file else { return }
        let snapshot = order.compactMap { entries[$0] }
        await file.save(snapshot)
    }

    private func touch(_ reference: PullRequestReference) {
        order.removeAll { $0 == reference }
        order.append(reference)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }
}

/// Reads and writes the cache file one operation at a time, off the main thread.
actor PullRequestDetailCacheFile {
    /// Changes when the saved shape changes, so an old file is ignored rather than misread.
    static let version = 1

    private struct Saved: Codable {
        let version: Int
        /// Least recently used first.
        let entries: [PullRequestDetailCache.Entry]
    }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    /// The saved entries, least recently used first. Empty when there is no file or it no longer decodes.
    func load() -> [PullRequestDetailCache.Entry] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.version == Self.version else { return [] }
        return saved.entries
    }

    func save(_ entries: [PullRequestDetailCache.Entry]) {
        guard let data = try? JSONEncoder().encode(Saved(version: Self.version, entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
