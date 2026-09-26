import Foundation

/// Pull request details and comments loaded so far, so a pull request shows right away when it is opened again
/// or after a refresh loaded it in the background. Keeps the most recently used entries.
@MainActor
final class PullRequestDetailCache {
    struct Entry: Equatable {
        var content: PullRequestDetailContent
        /// Nil until the comments first load.
        var comments: PullRequestComments?
    }

    let capacity: Int
    private var entries: [PullRequestReference: Entry] = [:]
    /// References from least to most recently used.
    private var order: [PullRequestReference] = []

    init(capacity: Int = 30) {
        self.capacity = capacity
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
        entries[reference] = Entry(content: content, comments: entries[reference]?.comments)
        touch(reference)
        evictIfNeeded()
    }

    /// Stores a pull request's comments. Ignored until its detail is cached, since comments alone cannot be shown.
    func store(_ comments: PullRequestComments, for reference: PullRequestReference) {
        guard entries[reference] != nil else { return }
        entries[reference]?.comments = comments
        touch(reference)
    }

    /// Whether the cached copy is missing, incomplete, or older than the list's `updatedAt`.
    func needsRefresh(_ reference: PullRequestReference, updatedAt: Date) -> Bool {
        guard let entry = entries[reference],
              entry.comments != nil,
              let cachedAt = entry.content.detail.updatedAt else { return true }
        return updatedAt > cachedAt
    }

    func removeAll() {
        entries = [:]
        order = []
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
