import Foundation

/// A write the user made that GitHub hasn't confirmed yet. It shows on top of the pull request as last loaded
/// until the sync engine sends it and saves what GitHub returns. Most kinds set a value, so sending one again after
/// a restart is safe; a comment adds one, so it isn't sent again without the user.
struct PendingChange: Identifiable, Equatable {
    enum Kind: Equatable, Codable {
        case title(String)
        /// The whole description, such as after checking a task box.
        case body(String)
        /// Marks a file as viewed or not: the pull request's node ID, the file's path, and the new state.
        case fileViewed(pullRequestID: String, path: String, viewed: Bool)
        case threadResolved(threadID: String, resolved: Bool)
        case reviewRequested(name: String, kind: PullRequestReviewer.Kind, requested: Bool)
        /// A general comment, a reply, or a new thread on the diff, shown as written by `authorLogin` (the viewer).
        case comment(NewPullRequestComment, authorLogin: String?)

        /// The `pending_change.kind` column.
        var name: String {
            switch self {
            case .title: return "title"
            case .body: return "body"
            case .fileViewed: return "fileViewed"
            case .threadResolved: return "threadResolved"
            case .reviewRequested: return "reviewRequested"
            case .comment: return "comment"
            }
        }

        /// Whether sending it twice does no harm, so it's sent again after a restart. A comment would post twice.
        var isSafeToResend: Bool {
            if case .comment = self { return false }
            return true
        }

        /// What it sets, so a newer change to the same field replaces it. Nil for a comment, which adds one.
        var field: Field? {
            switch self {
            case .title: return .title
            case .body: return .body
            case .fileViewed(_, let path, _): return .fileViewed(path: path)
            case .threadResolved(let threadID, _): return .threadResolved(threadID: threadID)
            case .reviewRequested(let name, let kind, _):
                return .reviewRequested(reviewerID: PullRequestReviewer.id(name: name, kind: kind))
            case .comment:
                return nil
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
        /// GitHub refused it, or a comment may not have reached GitHub. It stays shown until the user retries or
        /// discards it.
        case failed
    }

    /// Why a comment left by the last run waits for the user: it may have posted, so sending it again could post twice.
    static let notSentAfterQuitError = "Not sent — the app quit before GitHub answered."

    let id: UUID
    let reference: PullRequestReference
    var kind: Kind
    let createdAt: Date
    var state = State.pending
    var error: String?
    /// The REST ID of the comment GitHub posted for this change. Once GitHub's copy has it, it shows instead.
    var postedCommentID: Int?

    init(id: UUID = UUID(), reference: PullRequestReference, kind: Kind, createdAt: Date = Date(),
         state: State = .pending, error: String? = nil, postedCommentID: Int? = nil) {
        self.id = id
        self.reference = reference
        self.kind = kind
        self.createdAt = createdAt
        self.state = state
        self.error = error
        self.postedCommentID = postedCommentID
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
        case .comment(let comment, let authorLogin):
            entry.comments = entry.comments.map {
                apply(comment, authorLogin: authorLogin, of: change, to: $0, headSHA: detail.headSHA)
            }
            return entry
        }
        entry.content = PullRequestDetailContent(detail: detail, files: files)
        return entry
    }

    /// Adds the comment where GitHub will show it: after the general comments, at the end of its thread, or as a new
    /// thread on its line.
    private static func apply(_ comment: NewPullRequestComment, authorLogin: String?, of change: PendingChange,
                              to comments: PullRequestComments, headSHA: String) -> PullRequestComments {
        // Once GitHub's copy has the posted comment, that shows instead, so it never shows twice.
        if let posted = change.postedCommentID, comments.contains(databaseID: posted) { return comments }
        let shown = PullRequestComment(id: "pending-\(change.id.uuidString)", databaseID: change.postedCommentID ?? 0,
                                       authorLogin: authorLogin ?? "", body: comment.body,
                                       createdAt: change.createdAt, htmlURL: nil, pendingChangeID: change.id)
        switch comment {
        case .general:
            return comments.adding(shown)
        case .reply(_, let commentID):
            return comments.adding(shown, toThreadStartedBy: commentID)
        case .inline(_, let commitID, let anchor):
            // GitHub keeps a comment on the commit it was written on. Once new commits move the head, that line may
            // hold other code, so the comment shows with the outdated conversations instead of on a line.
            let isOutdated = commitID != headSHA
            return comments.adding(ReviewThread(id: shown.id, path: anchor.path, line: isOutdated ? nil : anchor.line,
                                                startLine: nil, side: anchor.side, isResolved: false,
                                                isOutdated: isOutdated, comments: [shown]))
        }
    }
}
