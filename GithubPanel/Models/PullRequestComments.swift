import Foundation

/// One comment, either on the pull request itself or in a review thread on the diff.
struct PullRequestComment: Identifiable, Equatable, Codable {
    /// The GraphQL node ID.
    let id: String
    /// The REST ID. Replies to a review thread are posted against its first comment's REST ID.
    let databaseID: Int
    let authorLogin: String
    let body: String
    let createdAt: Date
    let htmlURL: URL?
    /// Whether the comment is a draft in the viewer's pending review, which only the viewer can see until it is submitted.
    var isPending = false
    /// The viewer's comment GitHub hasn't confirmed yet: the pending change that shows it. Nil for GitHub's comments.
    var pendingChangeID: UUID?
    /// A submitted review's verdict, for a review in the Activity list. Nil for a comment.
    var reviewState: PullRequestReviewer.State?
}

/// Which side of the diff a review comment sits on: `left` is the old file, `right` is the new file.
enum DiffSide: String, Equatable, Hashable, Codable {
    case left = "LEFT"
    case right = "RIGHT"
}

/// The diff line a review comment is attached to.
struct DiffCommentAnchor: Hashable, Codable {
    let path: String
    let line: Int
    let side: DiffSide

    /// Where a new comment on this unified-view line goes: deletions on the old side, everything else on the new side.
    static func unified(path: String, line: DiffDisplayLine) -> DiffCommentAnchor? {
        switch line.kind {
        case .deletion:
            return line.oldLineNumber.map { DiffCommentAnchor(path: path, line: $0, side: .left) }
        case .addition, .context:
            return line.newLineNumber.map { DiffCommentAnchor(path: path, line: $0, side: .right) }
        case .hunk, .note:
            return nil
        }
    }

    /// Where a new comment on one half of a split-view row goes.
    static func split(path: String, line: DiffDisplayLine?, side: DiffSide) -> DiffCommentAnchor? {
        guard let line, line.kind != .hunk, line.kind != .note else { return nil }
        let number = side == .left ? line.oldLineNumber : line.newLineNumber
        return number.map { DiffCommentAnchor(path: path, line: $0, side: side) }
    }

    /// Every anchor a line can hold threads for. A context line is on both sides.
    static func all(path: String, line: DiffDisplayLine) -> [DiffCommentAnchor] {
        var anchors: [DiffCommentAnchor] = []
        if line.kind == .deletion || line.kind == .context, let old = line.oldLineNumber {
            anchors.append(DiffCommentAnchor(path: path, line: old, side: .left))
        }
        if line.kind == .addition || line.kind == .context, let new = line.newLineNumber {
            anchors.append(DiffCommentAnchor(path: path, line: new, side: .right))
        }
        return anchors
    }
}

/// A conversation on one line (or range of lines) of the diff.
struct ReviewThread: Identifiable, Equatable, Codable {
    /// The GraphQL node ID.
    let id: String
    let path: String
    /// The last line the thread covers. GitHub leaves it out once the lines change and the thread is outdated.
    let line: Int?
    /// The first line of a multi-line comment.
    let startLine: Int?
    let side: DiffSide
    let isResolved: Bool
    let isOutdated: Bool
    let comments: [PullRequestComment]

    var anchor: DiffCommentAnchor? {
        line.map { DiffCommentAnchor(path: path, line: $0, side: side) }
    }

    /// A thread started in the viewer's pending review. GitHub cannot resolve it until the review is submitted.
    var isPending: Bool {
        !comments.isEmpty && comments.allSatisfy(\.isPending)
    }

    func settingResolved(_ isResolved: Bool) -> ReviewThread {
        ReviewThread(id: id, path: path, line: line, startLine: startLine, side: side, isResolved: isResolved,
                     isOutdated: isOutdated, comments: comments)
    }

    func replacingComments(_ comments: [PullRequestComment]) -> ReviewThread {
        ReviewThread(id: id, path: path, line: line, startLine: startLine, side: side,
                     isResolved: isResolved, isOutdated: isOutdated, comments: comments)
    }
}

/// How much of a pull request's discussion to load. A busy pull request loads part of it, and the "more"
/// buttons raise these by a step each.
struct PullRequestCommentLimits: Hashable, Codable {
    static let commentStep = 30
    static let threadStep = 50

    /// The newest general comments to load.
    var comments = commentStep
    /// The first review threads to load.
    var threads = threadStep

    func addingEarlierComments() -> PullRequestCommentLimits {
        var limits = self
        limits.comments += Self.commentStep
        return limits
    }

    func addingThreads() -> PullRequestCommentLimits {
        var limits = self
        limits.threads += Self.threadStep
        return limits
    }
}

/// The comments on one pull request: general comments on the Conversation tab and review threads on the diff.
struct PullRequestComments: Equatable, Codable {
    /// The newest general comments, oldest first. Earlier ones may not be loaded yet.
    let comments: [PullRequestComment]
    /// The first review threads. Later ones may not be loaded yet.
    let threads: [ReviewThread]
    /// The node ID of the viewer's pending review, whose draft comments wait to be submitted with a verdict.
    let pendingReviewID: String?
    /// How many general comments the pull request has, loaded or not.
    let totalCommentCount: Int
    /// How many review threads the pull request has, loaded or not.
    let totalThreadCount: Int
    /// The newest submitted reviews, oldest first, each with its verdict. They show in the Activity list.
    let reviews: [PullRequestComment]

    init(comments: [PullRequestComment], threads: [ReviewThread], pendingReviewID: String? = nil,
         totalCommentCount: Int? = nil, totalThreadCount: Int? = nil, reviews: [PullRequestComment] = []) {
        self.comments = comments
        self.threads = threads
        self.pendingReviewID = pendingReviewID
        self.totalCommentCount = max(totalCommentCount ?? 0, comments.count)
        self.totalThreadCount = max(totalThreadCount ?? 0, threads.count)
        self.reviews = reviews
    }

    /// Comments saved before reviews were loaded with them have none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comments = try container.decode([PullRequestComment].self, forKey: .comments)
        threads = try container.decode([ReviewThread].self, forKey: .threads)
        pendingReviewID = try container.decodeIfPresent(String.self, forKey: .pendingReviewID)
        totalCommentCount = try container.decode(Int.self, forKey: .totalCommentCount)
        totalThreadCount = try container.decode(Int.self, forKey: .totalThreadCount)
        reviews = try container.decodeIfPresent([PullRequestComment].self, forKey: .reviews) ?? []
    }

    static let empty = PullRequestComments(comments: [], threads: [])

    /// General comments older than the loaded ones.
    var earlierCommentCount: Int {
        totalCommentCount - comments.count
    }

    /// Review threads after the loaded ones.
    var unloadedThreadCount: Int {
        totalThreadCount - threads.count
    }

    /// Draft comments in the viewer's pending review.
    var pendingCommentCount: Int {
        threads.reduce(0) { $0 + $1.comments.filter(\.isPending).count }
    }

    /// General comments and submitted reviews, oldest first, as the Activity list shows them. While earlier comments
    /// aren't loaded, reviews from before the loaded ones are left out, so nothing shows out of order.
    var timeline: [PullRequestComment] {
        let start = earlierCommentCount > 0 ? comments.first?.createdAt : nil
        let shownReviews = reviews.filter { review in start.map { review.createdAt >= $0 } ?? true }
        guard !shownReviews.isEmpty else { return comments }
        // A stable merge, so a comment and a review made in the same instant keep their order.
        return (comments + shownReviews).enumerated()
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
            .map(\.element)
    }

    func settingThread(_ threadID: String, resolved: Bool) -> PullRequestComments {
        replacing(threads: threads.map { $0.id == threadID ? $0.settingResolved(resolved) : $0 })
    }

    /// Whether a loaded general comment, thread comment, or review has this REST ID.
    func contains(databaseID: Int) -> Bool {
        comments.contains { $0.databaseID == databaseID }
            || threads.contains { $0.comments.contains { $0.databaseID == databaseID } }
            || reviews.contains { $0.databaseID == databaseID }
    }

    /// A new general comment, after the loaded ones.
    func adding(_ comment: PullRequestComment) -> PullRequestComments {
        replacing(comments: comments + [comment], totalCommentCount: totalCommentCount + 1)
    }

    /// A new review thread, after the loaded ones.
    func adding(_ thread: ReviewThread) -> PullRequestComments {
        replacing(threads: threads + [thread], totalThreadCount: totalThreadCount + 1)
    }

    /// A reply at the end of the thread whose first comment has the REST ID `commentID`. Unchanged when that thread
    /// isn't loaded.
    func adding(_ reply: PullRequestComment, toThreadStartedBy commentID: Int) -> PullRequestComments {
        replacing(threads: threads.map { thread in
            thread.comments.first?.databaseID == commentID ? thread.replacingComments(thread.comments + [reply]) : thread
        })
    }

    /// A reply at the end of the thread with the node ID `threadID`. Unchanged when that thread isn't loaded.
    func adding(_ reply: PullRequestComment, toThread threadID: String) -> PullRequestComments {
        replacing(threads: threads.map { $0.id == threadID ? $0.replacingComments($0.comments + [reply]) : $0 })
    }

    /// A newly submitted review, after the loaded ones.
    func adding(review: PullRequestComment) -> PullRequestComments {
        replacing(reviews: reviews + [review])
    }

    func settingPendingReviewID(_ pendingReviewID: String?) -> PullRequestComments {
        PullRequestComments(comments: comments, threads: threads, pendingReviewID: pendingReviewID,
                            totalCommentCount: totalCommentCount, totalThreadCount: totalThreadCount, reviews: reviews)
    }

    /// The comments once the pending review is submitted: its drafts are published, and no review is pending.
    func publishingPendingReview() -> PullRequestComments {
        replacing(threads: threads.map { thread in
            thread.replacingComments(thread.comments.map { comment in
                var comment = comment
                comment.isPending = false
                return comment
            })
        }).settingPendingReviewID(nil)
    }

    /// The comments once the pending review is discarded: its drafts are gone, with the threads they started.
    func discardingPendingReview() -> PullRequestComments {
        let kept = threads.compactMap { thread -> ReviewThread? in
            let published = thread.comments.filter { !$0.isPending }
            return published.isEmpty ? nil : thread.replacingComments(published)
        }
        return replacing(threads: kept, totalThreadCount: totalThreadCount - (threads.count - kept.count))
            .settingPendingReviewID(nil)
    }

    private func replacing(comments: [PullRequestComment]? = nil, threads: [ReviewThread]? = nil,
                           reviews: [PullRequestComment]? = nil, totalCommentCount: Int? = nil,
                           totalThreadCount: Int? = nil) -> PullRequestComments {
        PullRequestComments(comments: comments ?? self.comments, threads: threads ?? self.threads,
                            pendingReviewID: pendingReviewID,
                            totalCommentCount: totalCommentCount ?? self.totalCommentCount,
                            totalThreadCount: totalThreadCount ?? self.totalThreadCount,
                            reviews: reviews ?? self.reviews)
    }
}

/// A comment to post.
enum NewPullRequestComment: Equatable, Codable {
    /// A comment on the pull request's Conversation tab.
    case general(body: String)
    /// A new review thread on one diff line, against the given head commit.
    case inline(body: String, commitID: String, anchor: DiffCommentAnchor)
    /// A reply to a review thread, addressed by the REST ID of the thread's first comment.
    case reply(body: String, commentID: Int)

    var body: String {
        switch self {
        case let .general(body), let .inline(body, _, _), let .reply(body, _): return body
        }
    }
}

/// A draft comment for the viewer's pending review. GitHub publishes it only when the review is submitted.
enum PendingReviewComment: Equatable, Codable {
    /// A new review thread on one diff line.
    case thread(body: String, anchor: DiffCommentAnchor)
    /// A reply to a review thread, addressed by the thread's node ID.
    case reply(body: String, threadID: String)

    var body: String {
        switch self {
        case let .thread(body, _), let .reply(body, _): return body
        }
    }
}

/// One file's review threads, grouped by the diff line they sit on.
struct ReviewThreadIndex: Equatable {
    private let byAnchor: [DiffCommentAnchor: [ReviewThread]]
    let threads: [ReviewThread]

    init(threads: [ReviewThread]) {
        self.threads = threads
        var byAnchor: [DiffCommentAnchor: [ReviewThread]] = [:]
        for thread in threads {
            guard let anchor = thread.anchor else { continue }
            byAnchor[anchor, default: []].append(thread)
        }
        self.byAnchor = byAnchor
    }

    func threads(at anchor: DiffCommentAnchor?) -> [ReviewThread] {
        anchor.flatMap { byAnchor[$0] } ?? []
    }

    /// Threads shown under this line: the old side's first, then the new side's.
    func threads(for line: DiffDisplayLine, path: String) -> [ReviewThread] {
        DiffCommentAnchor.all(path: path, line: line).flatMap { byAnchor[$0] ?? [] }
    }

    /// Threads with no line in `lines` to sit under, such as outdated ones. They are listed after the diff.
    func unplacedThreads(in lines: [DiffDisplayLine], path: String) -> [ReviewThread] {
        let shown = Set(lines.flatMap { DiffCommentAnchor.all(path: path, line: $0) })
        return threads.filter { thread in
            guard let anchor = thread.anchor else { return true }
            return !shown.contains(anchor)
        }
    }
}
