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
    /// Resolves or unresolves one review thread: its node ID and the new state.
    typealias SetResolved = (String, Bool) async throws -> Void
    /// Saves a new title, description, or both. Nil leaves that field as it is on GitHub.
    typealias Edit = (PullRequestReference, String?, String?) async throws -> Void
    typealias SubmitReview = (NewPullRequestReview, PullRequestReference) async throws -> Void
    /// Merges the base branch into the head branch: the pull request's node ID and the head commit it expects.
    typealias UpdateBranch = (String, String) async throws -> Void
    /// Starts a pending review: the pull request's node ID and the head commit. Returns the review's node ID.
    typealias StartPendingReview = (String, String) async throws -> String
    /// Adds a draft comment to the pending review with the given node ID.
    typealias AddPendingComment = (PendingReviewComment, String) async throws -> Void
    /// Submits the pending review with the given node ID, its verdict, and its message.
    typealias SubmitPendingReview = (String, PullRequestReviewEvent, String) async throws -> Void
    /// Discards the pending review with the given node ID.
    typealias DeletePendingReview = (String) async throws -> Void
    typealias FetchChecks = (PullRequestReference) async throws -> PullRequestChecks
    /// Runs failed checks again in the given repository.
    typealias RerunChecks = (CheckRerun, String) async throws -> Void
    /// Users and teams the reviewer picker offers for a search.
    typealias FetchReviewerCandidates = (PullRequestReference, String) async throws -> [ReviewerCandidate]
    /// Requests a review from a user or team, or removes the request: its name, kind, and whether it is requested.
    typealias SetReviewRequested = (PullRequestReference, String, PullRequestReviewer.Kind, Bool) async throws -> Void

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
    /// The verdict of the review submitted from this view, once GitHub accepts it.
    @Published private(set) var submittedReview: PullRequestReviewEvent?
    /// Whether an Update branch request is in flight.
    @Published private(set) var isUpdatingBranch = false
    /// The checks on the head commit. Nil until they first load.
    @Published private(set) var checks: PullRequestChecks?
    /// Reruns GitHub has not answered yet, so their buttons cannot be pressed twice.
    @Published private(set) var rerunsInFlight: Set<CheckRerun> = []
    /// Reviewers whose request is being added or removed, by `PullRequestReviewer.id`.
    @Published private(set) var reviewRequestsInFlight: Set<String> = []

    private let fetch: Fetch
    private let syncViewed: SetViewed
    private let fetchComments: FetchComments
    private let sendComment: PostComment
    private let sendResolved: SetResolved
    private let sendEdit: Edit
    private let sendReview: SubmitReview
    private let sendUpdateBranch: UpdateBranch
    private let sendStartPendingReview: StartPendingReview
    private let sendPendingComment: AddPendingComment
    private let sendSubmitPendingReview: SubmitPendingReview
    private let sendDeletePendingReview: DeletePendingReview
    private let fetchChecks: FetchChecks
    private let sendRerun: RerunChecks
    private let fetchCandidates: FetchReviewerCandidates
    private let sendReviewRequest: SetReviewRequested
    /// The pending review started here, until the comments reload with it. Keeps a failed reload from starting a second one.
    private var startedReviewID: String?
    private let cache: PullRequestDetailCache?
    /// Presentations built so far, keyed by filename and whether whitespace changes are hidden.
    private var presentations: [PresentationKey: DiffPresentation] = [:]
    /// The last task box save, so quick clicks reach GitHub in order and the last one wins.
    private var taskSave: Task<Void, Error>?

    private struct PresentationKey: Hashable {
        let filename: String
        let hideWhitespace: Bool
    }

    init(reference: PullRequestReference,
         fetch: @escaping Fetch,
         setViewed: @escaping SetViewed = { _, _, _ in },
         fetchComments: @escaping FetchComments = { _ in .empty },
         postComment: @escaping PostComment = { _, _ in },
         setResolved: @escaping SetResolved = { _, _ in },
         edit: @escaping Edit = { _, _, _ in },
         submitReview: @escaping SubmitReview = { _, _ in },
         updateBranch: @escaping UpdateBranch = { _, _ in },
         startPendingReview: @escaping StartPendingReview = { _, _ in "" },
         addPendingComment: @escaping AddPendingComment = { _, _ in },
         submitPendingReview: @escaping SubmitPendingReview = { _, _, _ in },
         deletePendingReview: @escaping DeletePendingReview = { _ in },
         fetchChecks: @escaping FetchChecks = { _ in .empty },
         rerunChecks: @escaping RerunChecks = { _, _ in },
         fetchReviewerCandidates: @escaping FetchReviewerCandidates = { _, _ in [] },
         setReviewRequested: @escaping SetReviewRequested = { _, _, _, _ in },
         cache: PullRequestDetailCache? = nil) {
        self.reference = reference
        self.fetch = fetch
        self.syncViewed = setViewed
        self.fetchComments = fetchComments
        self.sendComment = postComment
        self.sendResolved = setResolved
        self.sendEdit = edit
        self.sendReview = submitReview
        self.sendUpdateBranch = updateBranch
        self.sendStartPendingReview = startPendingReview
        self.sendPendingComment = addPendingComment
        self.sendSubmitPendingReview = submitPendingReview
        self.sendDeletePendingReview = deletePendingReview
        self.fetchChecks = fetchChecks
        self.sendRerun = rerunChecks
        self.fetchCandidates = fetchReviewerCandidates
        self.sendReviewRequest = setReviewRequested
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
                  setResolved: { [monitor] threadID, resolved in
                      try await monitor.setReviewThreadResolved(threadID: threadID, resolved: resolved)
                  },
                  edit: { [monitor] reference, title, body in
                      try await monitor.editPullRequest(reference, title: title, body: body)
                  },
                  submitReview: { [monitor] review, reference in
                      try await monitor.submitReview(review, on: reference)
                  },
                  updateBranch: { [monitor] pullRequestID, headSHA in
                      try await monitor.updatePullRequestBranch(pullRequestID: pullRequestID, expectedHeadSHA: headSHA)
                  },
                  startPendingReview: { [monitor] pullRequestID, commitID in
                      try await monitor.startPendingReview(pullRequestID: pullRequestID, commitID: commitID)
                  },
                  addPendingComment: { [monitor] comment, reviewID in
                      try await monitor.addPendingReviewComment(comment, reviewID: reviewID)
                  },
                  submitPendingReview: { [monitor] reviewID, event, body in
                      try await monitor.submitPendingReview(reviewID: reviewID, event: event, body: body)
                  },
                  deletePendingReview: { [monitor] reviewID in
                      try await monitor.deletePendingReview(reviewID: reviewID)
                  },
                  fetchChecks: { [monitor] reference in try await monitor.fetchPullRequestChecks(reference) },
                  rerunChecks: { [monitor] rerun, repoFullName in
                      try await monitor.rerunChecks(rerun, in: repoFullName)
                  },
                  fetchReviewerCandidates: { [monitor] reference, query in
                      try await monitor.fetchReviewerCandidates(reference, query: query)
                  },
                  setReviewRequested: { [monitor] reference, name, kind, requested in
                      try await monitor.setReviewRequested(name, kind: kind, requested: requested, on: reference)
                  },
                  cache: monitor.detailCache)
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // The comments and checks load alongside the diff, which shows as soon as it arrives.
        async let loadedComments = fetchComments(reference)
        async let loadedChecks = fetchChecks(reference)
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
        do {
            checks = try await loadedChecks
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs the failed checks of one workflow run or check suite again, then reloads the checks to show them pending.
    func rerun(_ rerun: CheckRerun) async {
        guard !rerunsInFlight.contains(rerun) else { return }
        rerunsInFlight.insert(rerun)
        defer { rerunsInFlight.remove(rerun) }
        do {
            try await sendRerun(rerun, reference.repoFullName)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await reloadChecks()
    }

    /// Runs every failed check again, once per workflow run or check suite.
    func rerunFailedChecks() async {
        guard let reruns = checks?.failedReruns.filter({ !rerunsInFlight.contains($0) }), !reruns.isEmpty else { return }
        rerunsInFlight.formUnion(reruns)
        defer { rerunsInFlight.subtract(reruns) }
        var failure: Error?
        for rerun in reruns {
            do {
                try await sendRerun(rerun, reference.repoFullName)
            } catch {
                failure = error
            }
        }
        errorMessage = failure?.localizedDescription
        await reloadChecks()
    }

    private func reloadChecks() async {
        do {
            checks = try await fetchChecks(reference)
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
        startedReviewID = nil
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

    /// Checks or unchecks a task item in the description, like clicking its box on GitHub.
    /// Shows the change right away and puts the old description back if GitHub refuses it.
    func setTask(_ index: Int, checked: Bool) async {
        guard let old = content?.detail.body, content?.detail.canEdit == true,
              let body = MarkdownBlocks.settingTask(index, checked: checked, in: old), body != old else { return }
        setBody(body)
        let previous = taskSave
        let save = Task { [sendEdit, reference] in
            _ = await previous?.result
            try await sendEdit(reference, nil, body)
        }
        taskSave = save
        do {
            try await save.value
        } catch {
            // A later click already changed the description again; leave that one showing.
            if content?.detail.body == body { setBody(old) }
            errorMessage = error.localizedDescription
        }
    }

    private func setBody(_ body: String) {
        guard let current = content else { return }
        var detail = current.detail
        detail.body = body
        content = PullRequestDetailContent(detail: detail, files: current.files)
        cacheContent()
    }

    /// Whether the viewer may approve or request changes. GitHub does not let authors review their own pull request.
    var canReview: Bool {
        guard let detail = content?.detail else { return false }
        return !detail.isViewerAuthor && (detail.state == .open || detail.state == .draft)
    }

    /// The viewer's pending review, whose draft comments wait to be submitted with a verdict.
    var pendingReviewID: String? {
        startedReviewID ?? comments?.pendingReviewID
    }

    /// Draft comments waiting in the pending review.
    var pendingCommentCount: Int {
        comments?.pendingCommentCount ?? 0
    }

    /// Submits a review of the head commit that was loaded, publishing any draft comments with it.
    /// Throws when GitHub refuses it, so the form can keep the draft.
    func submitReview(_ event: PullRequestReviewEvent, body: String) async throws {
        guard canReview, let commitID = content?.detail.headSHA else { return }
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ReviewComposer.canSubmit(event, text: body, pendingCommentCount: pendingCommentCount) else { return }
        if let reviewID = pendingReviewID {
            try await sendSubmitPendingReview(reviewID, event, body)
            submittedReview = event
            await reloadCommentsAfterReviewChange()
        } else {
            try await sendReview(NewPullRequestReview(event: event, body: body, commitID: commitID), reference)
            submittedReview = event
        }
    }

    /// Discards the pending review and its draft comments. Throws when GitHub refuses, so the form can show the error.
    func discardPendingReview() async throws {
        guard let reviewID = pendingReviewID else { return }
        try await sendDeletePendingReview(reviewID)
        await reloadCommentsAfterReviewChange()
    }

    /// Adds a draft comment to the pending review, starting one on the loaded head commit if there is none yet.
    /// Throws when GitHub refuses, so the composer can keep the draft.
    func addToReview(_ comment: PendingReviewComment) async throws {
        guard canReview, let detail = content?.detail else { return }
        let reviewID: String
        if let pendingReviewID {
            reviewID = pendingReviewID
        } else {
            reviewID = try await sendStartPendingReview(detail.nodeID, detail.headSHA)
            startedReviewID = reviewID
        }
        try await sendPendingComment(comment, reviewID)
        do {
            try await reloadComments()
        } catch {
            // The draft was saved; only the refresh failed.
            errorMessage = error.localizedDescription
        }
    }

    /// Reloads the comments once the pending review is gone, so its drafts show as published or disappear.
    private func reloadCommentsAfterReviewChange() async {
        startedReviewID = nil
        do {
            try await reloadComments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reviewerCandidates(matching query: String) async throws -> [ReviewerCandidate] {
        try await fetchCandidates(reference, query)
    }

    /// Requests a review from a user or team, or removes their request, like toggling them in GitHub's reviewer picker.
    /// Shows the change once GitHub accepts it, then reloads the detail for GitHub's own view of the reviewers.
    func setReviewRequested(_ name: String, kind: PullRequestReviewer.Kind, requested: Bool) async {
        let id = PullRequestReviewer.id(name: name, kind: kind)
        guard content?.detail.canRequestReviewers == true, !reviewRequestsInFlight.contains(id) else { return }
        reviewRequestsInFlight.insert(id)
        defer { reviewRequestsInFlight.remove(id) }
        do {
            try await sendReviewRequest(reference, name, kind, requested)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if let current = content {
            var detail = current.detail
            detail.reviewers = detail.reviewers.settingRequest(name: name, kind: kind, requested: requested)
            content = PullRequestDetailContent(detail: detail, files: current.files)
            cacheContent()
        }
        if let fresh = try? await fetch(reference) {
            apply(fresh)
            cacheContent()
        }
    }

    /// Merges the base branch into the pull request's branch, then reloads to show the new head commit.
    /// Hides the button right away so it cannot be pressed twice; a failure shows the error and brings it back.
    func updateBranch() async {
        guard let detail = content?.detail, detail.offersUpdateBranch, !isUpdatingBranch else { return }
        isUpdatingBranch = true
        defer { isUpdatingBranch = false }
        do {
            try await sendUpdateBranch(detail.nodeID, detail.headSHA)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        setCanUpdateBranch(false)
        errorMessage = nil
        await load()
    }

    private func setCanUpdateBranch(_ canUpdateBranch: Bool) {
        guard let current = content else { return }
        var detail = current.detail
        detail.canUpdateBranch = canUpdateBranch
        content = PullRequestDetailContent(detail: detail, files: current.files)
        cacheContent()
    }

    /// Whether new comments on the diff join the pending review instead of posting right away, like on GitHub once a review is started.
    var isReviewPending: Bool {
        canReview && pendingReviewID != nil
    }

    /// Posts a new review thread on a diff line, against the head commit that was loaded.
    /// Joins the pending review instead when one is started.
    func postInlineComment(_ body: String, at anchor: DiffCommentAnchor) async throws {
        if isReviewPending {
            try await addToReview(.thread(body: body, anchor: anchor))
            return
        }
        guard let commitID = content?.detail.headSHA else { return }
        try await post(.inline(body: body, commitID: commitID, anchor: anchor))
    }

    /// Replies to a thread, as a draft in the pending review when one is started.
    func reply(_ body: String, to thread: ReviewThread) async throws {
        if isReviewPending {
            try await addToReview(.reply(body: body, threadID: thread.id))
            return
        }
        guard let first = thread.comments.first else { return }
        try await post(.reply(body: body, commentID: first.databaseID))
    }

    /// Resolves or unresolves a review thread, then reloads the comments so it shows GitHub's state.
    /// Throws when GitHub refuses, so the thread can show the error.
    func setResolved(_ resolved: Bool, thread: ReviewThread) async throws {
        guard thread.isResolved != resolved else { return }
        try await sendResolved(thread.id, resolved)
        do {
            try await reloadComments()
        } catch {
            // The thread changed; only the refresh failed.
            errorMessage = error.localizedDescription
        }
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
