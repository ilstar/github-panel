import Foundation

/// A write the user made that GitHub hasn't confirmed yet. It shows on top of the pull request as last loaded
/// until the sync engine sends it and saves what GitHub returns. Most kinds set a value, so sending one again after
/// a restart is safe; a comment or a review adds one, so it isn't sent again without the user.
struct PendingChange: Identifiable, Equatable {
    /// The pending review a change goes to: one GitHub started, or the one an earlier change is starting. Once that
    /// change starts it, the later changes get its node ID.
    enum ReviewTarget: Equatable, Codable {
        case review(id: String)
        /// The `startReview` change with this ID.
        case startedBy(UUID)
    }

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
        /// A review submitted in one step, without a pending review.
        case review(NewPullRequestReview, authorLogin: String?)
        /// Starts a pending review on the pull request with this node ID, at the head commit. `reviewID` is the
        /// review's node ID once GitHub started it.
        case startReview(pullRequestID: String, commitID: String, reviewID: String?)
        /// A draft comment for a pending review.
        case reviewComment(PendingReviewComment, review: ReviewTarget, authorLogin: String?)
        /// Submits a pending review, publishing its drafts with the verdict and message.
        case submitPendingReview(review: ReviewTarget, event: PullRequestReviewEvent, body: String, authorLogin: String?)
        /// Discards a pending review and its drafts.
        case discardPendingReview(review: ReviewTarget)

        /// The `pending_change.kind` column.
        var name: String {
            switch self {
            case .title: return "title"
            case .body: return "body"
            case .fileViewed: return "fileViewed"
            case .threadResolved: return "threadResolved"
            case .reviewRequested: return "reviewRequested"
            case .comment: return "comment"
            case .review: return "review"
            case .startReview: return "startReview"
            case .reviewComment: return "reviewComment"
            case .submitPendingReview: return "submitPendingReview"
            case .discardPendingReview: return "discardPendingReview"
            }
        }

        /// Whether sending it twice does no harm, so it's sent again after a restart. A comment or a review would
        /// post twice, and a second pending review can't be started. Deleting a review that's already gone is harmless.
        var isSafeToResend: Bool {
            switch self {
            case .title, .body, .fileViewed, .threadResolved, .reviewRequested, .discardPendingReview:
                return true
            case .comment, .review, .startReview, .reviewComment, .submitPendingReview:
                return false
            }
        }

        /// The pending review it goes to.
        var reviewTarget: ReviewTarget? {
            switch self {
            case .reviewComment(_, let review, _), .submitPendingReview(let review, _, _, _),
                 .discardPendingReview(let review):
                return review
            case .title, .body, .fileViewed, .threadResolved, .reviewRequested, .comment, .review, .startReview:
                return nil
            }
        }

        /// The same change sent to the pending review `reviewID`, once the change starting it has.
        func sending(toReview reviewID: String) -> Kind {
            switch self {
            case .reviewComment(let comment, _, let authorLogin):
                return .reviewComment(comment, review: .review(id: reviewID), authorLogin: authorLogin)
            case .submitPendingReview(_, let event, let body, let authorLogin):
                return .submitPendingReview(review: .review(id: reviewID), event: event, body: body,
                                            authorLogin: authorLogin)
            case .discardPendingReview:
                return .discardPendingReview(review: .review(id: reviewID))
            case .title, .body, .fileViewed, .threadResolved, .reviewRequested, .comment, .review, .startReview:
                return self
            }
        }

        /// The text the user wrote, which a failed change offers to copy.
        var text: String? {
            switch self {
            case .comment(let comment, _): return comment.body
            case .review(let review, _): return review.body.isEmpty ? nil : review.body
            case .reviewComment(let comment, _, _): return comment.body
            case .submitPendingReview(_, _, let body, _): return body.isEmpty ? nil : body
            case .title, .body, .fileViewed, .threadResolved, .reviewRequested, .startReview, .discardPendingReview:
                return nil
            }
        }

        /// What GitHub may have done when a request for it failed without an answer, for the error.
        var outcomeIfSent: String {
            switch self {
            case .review, .submitPendingReview: return "submitted it"
            case .startReview: return "started the review"
            case .reviewComment: return "added it to your review"
            case .discardPendingReview: return "discarded it"
            case .title, .body, .fileViewed, .threadResolved, .reviewRequested, .comment: return "posted it"
            }
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
            case .comment, .review, .startReview, .reviewComment, .submitPendingReview, .discardPendingReview:
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
        /// GitHub refused it, or a comment or review may not have reached GitHub. It stays shown until the user
        /// retries or discards it.
        case failed
    }

    /// Why a comment or review left by the last run waits for the user: it may have posted, so sending it again could
    /// post twice.
    static let notSentAfterQuitError = "Not sent — the app quit before GitHub answered."

    /// Why a change to a pending review wasn't sent: the change starting the review failed.
    struct ReviewNotStartedError: LocalizedError {
        var errorDescription: String? { "Not sent — GitHub didn't start your pending review." }
    }

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

    /// Whether GitHub took it, so it shows once the next load does: a comment or review GitHub posted, or a review
    /// it started.
    var wasPosted: Bool {
        if postedCommentID != nil { return true }
        if case .startReview(_, _, let reviewID) = kind { return reviewID != nil }
        return false
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
        case .review(let review, let authorLogin):
            detail.reviewers = settingReview(review.event, by: authorLogin, on: detail.reviewers)
            entry.comments = entry.comments.map {
                addingReview(review.event, body: review.body, authorLogin: authorLogin, of: change, to: $0)
            }
        case .startReview(_, _, let reviewID):
            // Once GitHub started it, new drafts join it even before the comments reload with it.
            if let reviewID, entry.comments?.pendingReviewID == nil {
                entry.comments = entry.comments?.settingPendingReviewID(reviewID)
            }
            return entry
        case .reviewComment(let comment, _, let authorLogin):
            entry.comments = entry.comments.map { apply(comment, authorLogin: authorLogin, of: change, to: $0) }
            return entry
        case .submitPendingReview(_, let event, let body, let authorLogin):
            detail.reviewers = settingReview(event, by: authorLogin, on: detail.reviewers)
            entry.comments = entry.comments.map {
                addingReview(event, body: body, authorLogin: authorLogin, of: change, to: $0.publishingPendingReview())
            }
        case .discardPendingReview:
            entry.comments = entry.comments?.discardingPendingReview()
            return entry
        }
        entry.content = PullRequestDetailContent(detail: detail, files: files)
        return entry
    }

    /// The viewer shows as having reviewed, unless who they are isn't known yet.
    private static func settingReview(_ event: PullRequestReviewEvent, by authorLogin: String?,
                                      on reviewers: PullRequestReviewers) -> PullRequestReviewers {
        guard let authorLogin, !authorLogin.isEmpty else { return reviewers }
        return reviewers.settingReview(by: authorLogin, state: event.reviewerState)
    }

    /// Adds the review to the Activity list, as the viewer's, unless GitHub's copy already has it.
    private static func addingReview(_ event: PullRequestReviewEvent, body: String, authorLogin: String?,
                                     of change: PendingChange, to comments: PullRequestComments) -> PullRequestComments {
        if let posted = change.postedCommentID, comments.contains(databaseID: posted) { return comments }
        return comments.adding(review: PullRequestComment(id: "pending-\(change.id.uuidString)",
                                                          databaseID: change.postedCommentID ?? 0,
                                                          authorLogin: authorLogin ?? "", body: body,
                                                          createdAt: change.createdAt, htmlURL: nil,
                                                          pendingChangeID: change.id,
                                                          reviewState: event.reviewerState))
    }

    /// Adds a draft where GitHub will show it, marked as part of the pending review: as a new thread on its line, or
    /// at the end of the thread it answers.
    private static func apply(_ comment: PendingReviewComment, authorLogin: String?, of change: PendingChange,
                              to comments: PullRequestComments) -> PullRequestComments {
        if let posted = change.postedCommentID, comments.contains(databaseID: posted) { return comments }
        let shown = PullRequestComment(id: "pending-\(change.id.uuidString)", databaseID: change.postedCommentID ?? 0,
                                       authorLogin: authorLogin ?? "", body: comment.body,
                                       createdAt: change.createdAt, htmlURL: nil, isPending: true,
                                       pendingChangeID: change.id)
        switch comment {
        case .thread(_, let anchor):
            return comments.adding(ReviewThread(id: shown.id, path: anchor.path, line: anchor.line, startLine: nil,
                                                side: anchor.side, isResolved: false, isOutdated: false,
                                                comments: [shown]))
        case .reply(_, let threadID):
            return comments.adding(shown, toThread: threadID)
        }
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
