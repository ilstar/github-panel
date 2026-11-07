import Foundation

/// A write the user made that GitHub hasn't confirmed yet. It shows on top of the pull request as last loaded
/// until the sync engine sends it and saves what GitHub returns. Every kind sets a value rather than adding one,
/// so sending it again after a restart is safe.
struct PendingChange: Identifiable, Equatable {
    enum Kind: Equatable, Codable {
        case title(String)
        /// The whole description, such as after checking a task box.
        case body(String)
        /// Marks a file as viewed or not: the pull request's node ID, the file's path, and the new state.
        case fileViewed(pullRequestID: String, path: String, viewed: Bool)
        case threadResolved(threadID: String, resolved: Bool)
        case reviewRequested(name: String, kind: PullRequestReviewer.Kind, requested: Bool)

        /// The `pending_change.kind` column.
        var name: String {
            switch self {
            case .title: return "title"
            case .body: return "body"
            case .fileViewed: return "fileViewed"
            case .threadResolved: return "threadResolved"
            case .reviewRequested: return "reviewRequested"
            }
        }

        var field: Field {
            switch self {
            case .title: return .title
            case .body: return .body
            case .fileViewed(_, let path, _): return .fileViewed(path: path)
            case .threadResolved(let threadID, _): return .threadResolved(threadID: threadID)
            case .reviewRequested(let name, let kind, _):
                return .reviewRequested(reviewerID: PullRequestReviewer.id(name: name, kind: kind))
            }
        }
    }

    /// What a change sets. A newer change to the same field replaces one that hasn't started sending.
    enum Field: Hashable {
        case title
        case body
        case fileViewed(path: String)
        case threadResolved(threadID: String)
        /// A user or team, by `PullRequestReviewer.id`.
        case reviewRequested(reviewerID: String)
    }

    enum State: String {
        case pending
        /// Sent to GitHub, which hasn't answered yet.
        case sending
        /// GitHub refused it. It stays shown until the user retries or discards it.
        case failed
    }

    let id: UUID
    let reference: PullRequestReference
    var kind: Kind
    let createdAt: Date
    var state = State.pending
    var error: String?

    init(id: UUID = UUID(), reference: PullRequestReference, kind: Kind, createdAt: Date = Date(),
         state: State = .pending, error: String? = nil) {
        self.id = id
        self.reference = reference
        self.kind = kind
        self.createdAt = createdAt
        self.state = state
        self.error = error
    }

    /// The entry with each change applied in order, which is what the detail view shows.
    static func apply(_ changes: [PendingChange], to entry: PullRequestDetailCache.Entry) -> PullRequestDetailCache.Entry {
        changes.reduce(entry) { entry, change in apply(change, to: entry) }
    }

    static func apply(_ change: PendingChange, to entry: PullRequestDetailCache.Entry) -> PullRequestDetailCache.Entry {
        var entry = entry
        var detail = entry.content.detail
        var files = entry.content.files
        switch change.kind {
        case .title(let title):
            detail.title = title
        case .body(let body):
            detail.body = body
        case .fileViewed(_, let path, let viewed):
            files = files.map { file in
                guard file.filename == path else { return file }
                var file = file
                file.isViewed = viewed
                return file
            }
        case .threadResolved(let threadID, let resolved):
            entry.comments = entry.comments?.settingThread(threadID, resolved: resolved)
            return entry
        case .reviewRequested(let name, let kind, let requested):
            detail.reviewers = detail.reviewers.settingRequest(name: name, kind: kind, requested: requested)
        }
        entry.content = PullRequestDetailContent(detail: detail, files: files)
        return entry
    }
}
