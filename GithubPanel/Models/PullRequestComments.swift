import Foundation

/// One comment, either on the pull request itself or in a review thread on the diff.
struct PullRequestComment: Identifiable, Equatable {
    /// The GraphQL node ID.
    let id: String
    /// The REST ID. Replies to a review thread are posted against its first comment's REST ID.
    let databaseID: Int
    let authorLogin: String
    let body: String
    let createdAt: Date
    let htmlURL: URL?
}

/// Which side of the diff a review comment sits on: `left` is the old file, `right` is the new file.
enum DiffSide: String, Equatable, Hashable {
    case left = "LEFT"
    case right = "RIGHT"
}

/// The diff line a review comment is attached to.
struct DiffCommentAnchor: Hashable {
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
struct ReviewThread: Identifiable, Equatable {
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
}

/// The comments on one pull request: general comments on the Conversation tab and review threads on the diff.
struct PullRequestComments: Equatable {
    let comments: [PullRequestComment]
    let threads: [ReviewThread]

    static let empty = PullRequestComments(comments: [], threads: [])
}

/// A comment to post.
enum NewPullRequestComment: Equatable {
    /// A comment on the pull request's Conversation tab.
    case general(body: String)
    /// A new review thread on one diff line, against the given head commit.
    case inline(body: String, commitID: String, anchor: DiffCommentAnchor)
    /// A reply to a review thread, addressed by the REST ID of the thread's first comment.
    case reply(body: String, commentID: Int)
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
