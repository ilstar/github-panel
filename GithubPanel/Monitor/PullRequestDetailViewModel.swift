import Foundation

/// Loads one pull request's detail and changed files for the detail window.
/// Starts from the shared cache when it has the pull request, then reloads it in the background.
@MainActor
final class PullRequestDetailViewModel: ObservableObject {
    typealias Fetch = (PullRequestReference) async throws -> PullRequestDetailContent
    /// Marks or unmarks one file as viewed: the pull request's node ID, the file path, and the new state.
    typealias SetViewed = (String, String, Bool) async throws -> Void
    typealias FetchComments = (PullRequestReference) async throws -> PullRequestComments
    typealias PostComment = (NewPullRequestComment, PullRequestReference) async throws -> Void
    /// Saves a new title, description, or both. Nil leaves that field as it is on GitHub.
    typealias Edit = (PullRequestReference, String?, String?) async throws -> Void

    let reference: PullRequestReference
    /// The last loaded content. Kept when a reload fails so the window does not go blank.
    @Published private(set) var content: PullRequestDetailContent?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// Parsed diff lines for each file, keyed by filename. Parsed once per load.
    @Published private(set) var diffLines: [String: [DiffLine]] = [:]
    /// Filenames the viewer marked as viewed.
    @Published private(set) var viewedFiles: Set<String> = []
    /// General comments and review threads. Nil until they first load.
    @Published private(set) var comments: PullRequestComments?
    /// Review threads for each file, keyed by filename.
    @Published private(set) var threadIndexes: [String: ReviewThreadIndex] = [:]

    private let fetch: Fetch
    private let syncViewed: SetViewed
    private let fetchComments: FetchComments
    private let sendComment: PostComment
    private let sendEdit: Edit
    private let cache: PullRequestDetailCache?
    /// Presentations built so far, keyed by filename and whether whitespace changes are hidden.
    private var presentations: [PresentationKey: DiffPresentation] = [:]

    private struct PresentationKey: Hashable {
        let filename: String
        let hideWhitespace: Bool
    }

    init(reference: PullRequestReference,
         fetch: @escaping Fetch,
         setViewed: @escaping SetViewed = { _, _, _ in },
         fetchComments: @escaping FetchComments = { _ in .empty },
         postComment: @escaping PostComment = { _, _ in },
         edit: @escaping Edit = { _, _, _ in },
         cache: PullRequestDetailCache? = nil) {
        self.reference = reference
        self.fetch = fetch
        self.syncViewed = setViewed
        self.fetchComments = fetchComments
        self.sendComment = postComment
        self.sendEdit = edit
        self.cache = cache
        if let cached = cache?.entry(for: reference) {
            apply(cached.content)
            if let comments = cached.comments {
                apply(comments)
            }
        }
    }

    /// Talks to GitHub through the monitor, which holds the token.
    convenience init(reference: PullRequestReference, monitor: PRMonitor) {
        self.init(reference: reference,
                  fetch: { [monitor] reference in try await monitor.fetchPullRequestDetail(reference) },
                  setViewed: { [monitor] pullRequestID, path, viewed in
                      try await monitor.setFileViewed(pullRequestID: pullRequestID, path: path, viewed: viewed)
                  },
                  fetchComments: { [monitor] reference in try await monitor.fetchPullRequestComments(reference) },
                  postComment: { [monitor] comment, reference in
                      try await monitor.postPullRequestComment(comment, on: reference)
                  },
                  edit: { [monitor] reference, title, body in
                      try await monitor.editPullRequest(reference, title: title, body: body)
                  },
                  cache: monitor.detailCache)
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // The comments load alongside the diff, which shows as soon as it arrives.
        async let loadedComments = fetchComments(reference)
        do {
            apply(try await fetch(reference))
            cacheContent()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        do {
            let comments = try await loadedComments
            apply(comments)
            cache?.store(comments, for: reference)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shows loaded content. Skips identical content so a reload does not rebuild the diff.
    private func apply(_ loaded: PullRequestDetailContent) {
        guard loaded != content else { return }
        diffLines = Dictionary(loaded.files.map { ($0.filename, DiffParser.parse($0.patch ?? "")) },
                               uniquingKeysWith: { first, _ in first })
        presentations = [:]
        viewedFiles = Set(loaded.files.filter(\.isViewed).map(\.filename))
        content = loaded
    }

    private func apply(_ loaded: PullRequestComments) {
        threadIndexes = Dictionary(grouping: loaded.threads, by: \.path).mapValues(ReviewThreadIndex.init)
        comments = loaded
    }

    /// Saves the shown content, with the current viewed marks, to the shared cache.
    private func cacheContent() {
        guard let cache, let content else { return }
        let files = content.files.map { file in
            var file = file
            file.isViewed = viewedFiles.contains(file.filename)
            return file
        }
        cache.store(PullRequestDetailContent(detail: content.detail, files: files))
    }

    /// Posts a comment, then reloads the comments so it shows with GitHub's IDs.
    /// Throws when GitHub refuses the comment, so the composer can keep the draft.
    func post(_ comment: NewPullRequestComment) async throws {
        try await sendComment(comment, reference)
        do {
            try await reloadComments()
        } catch {
            // The comment was posted; only the refresh failed.
            errorMessage = error.localizedDescription
        }
    }

    /// Saves a new title, description, or both and shows them right away. A blank title is ignored, since GitHub requires one.
    /// Throws when GitHub refuses the edit, so the editor can keep the draft.
    func edit(title: String? = nil, body: String? = nil) async throws {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content?.detail.canEdit == true, title != nil || body != nil, title?.isEmpty != true else { return }
        try await sendEdit(reference, title, body)
        guard let current = content else { return }
        var detail = current.detail
        detail.title = title ?? detail.title
        detail.body = body ?? detail.body
        content = PullRequestDetailContent(detail: detail, files: current.files)
        cacheContent()
    }

    /// Posts a new review thread on a diff line, against the head commit that was loaded.
    func postInlineComment(_ body: String, at anchor: DiffCommentAnchor) async throws {
        guard let commitID = content?.detail.headSHA else { return }
        try await post(.inline(body: body, commitID: commitID, anchor: anchor))
    }

    func reply(_ body: String, to thread: ReviewThread) async throws {
        guard let first = thread.comments.first else { return }
        try await post(.reply(body: body, commentID: first.databaseID))
    }

    func threadIndex(for filename: String) -> ReviewThreadIndex {
        threadIndexes[filename] ?? ReviewThreadIndex(threads: [])
    }

    private func reloadComments() async throws {
        let loaded = try await fetchComments(reference)
        apply(loaded)
        cache?.store(loaded, for: reference)
    }

    /// The file's diff with word highlights, built on first use and then reused.
    func presentation(for filename: String, hideWhitespace: Bool) -> DiffPresentation {
        let key = PresentationKey(filename: filename, hideWhitespace: hideWhitespace)
        if let cached = presentations[key] { return cached }
        let presentation = DiffPresentation(lines: diffLines[filename] ?? [], hideWhitespace: hideWhitespace)
        presentations[key] = presentation
        return presentation
    }

    /// Updates the viewed mark right away and syncs it to GitHub, restoring it if GitHub refuses.
    func setViewed(_ viewed: Bool, filename: String) async {
        guard let pullRequestID = content?.detail.nodeID, viewedFiles.contains(filename) != viewed else { return }
        update(filename, viewed: viewed)
        do {
            try await syncViewed(pullRequestID, filename, viewed)
        } catch {
            update(filename, viewed: !viewed)
            errorMessage = error.localizedDescription
        }
    }

    private func update(_ filename: String, viewed: Bool) {
        if viewed {
            viewedFiles.insert(filename)
        } else {
            viewedFiles.remove(filename)
        }
        cacheContent()
    }
}
