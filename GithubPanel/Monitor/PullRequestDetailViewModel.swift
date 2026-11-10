import Foundation
import Combine

/// Shows one pull request's detail and changed files for the detail window.
/// Starts from the shared cache when it has the pull request, asks the sync engine to reload it,
/// and shows what the engine saves to the cache. Edits, viewed marks, resolved threads, review requests, comments and
/// reviews are pending changes: they show right away, and the engine sends them.
@MainActor
final class PullRequestDetailViewModel: ObservableObject {
    /// Merges the base branch into the head branch: the pull request's node ID and the head commit it expects.
    typealias UpdateBranch = (String, String) async throws -> Void
    /// Runs failed checks again in the given repository.
    typealias RerunChecks = (CheckRerun, String) async throws -> Void
    /// Users and teams the reviewer picker offers for a search.
    typealias FetchReviewerCandidates = (PullRequestReference, String) async throws -> [ReviewerCandidate]
    /// GitHub users the @mention menu offers for what was typed after the "@".
    typealias SearchMentionCandidates = (PullRequestReference, String) async throws -> [MentionCandidate]

    /// Which changes the Files tab shows.
    enum FileScope: Equatable {
        /// Every change in the pull request.
        case all
        /// Only what changed since the commit the viewer last reviewed, like GitHub's "Changes since your last review".
        case sinceLastReview
    }

    let reference: PullRequestReference
    /// The last loaded content. Kept when a reload fails so the window does not go blank.
    @Published private(set) var content: PullRequestDetailContent?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// Each file's diff lines, parsed the first time the file is shown.
    private var diffLines = LazyDiffLines()
    /// Filenames the viewer marked as viewed.
    @Published private(set) var viewedFiles: Set<String> = []
    /// General comments and review threads. Nil until they first load.
    @Published private(set) var comments: PullRequestComments?
    /// Review threads for each file, keyed by filename.
    @Published private(set) var threadIndexes: [String: ReviewThreadIndex] = [:]
    /// Whether earlier comments or more review threads are loading.
    @Published private(set) var isLoadingMoreComments = false
    /// The verdict of the review submitted from this view. Shows right away, and goes if GitHub refuses the review.
    @Published private(set) var submittedReview: PullRequestReviewEvent?
    /// Whether an Update branch request is in flight.
    @Published private(set) var isUpdatingBranch = false
    /// The checks on the head commit. Nil until they first load.
    @Published private(set) var checks: PullRequestChecks?
    /// Reruns GitHub has not answered yet, so their buttons cannot be pressed twice.
    @Published private(set) var rerunsInFlight: Set<CheckRerun> = []
    /// This pull request's changes GitHub hasn't confirmed, oldest first. `content` and `comments` show them already.
    @Published private(set) var pendingChanges: [PendingChange] = []
    @Published private(set) var fileScope = FileScope.all
    /// The files changed since the viewer's last review. Nil until they load for the current head commit.
    @Published private(set) var filesSinceLastReview: [PullRequestFile]?
    @Published private(set) var isLoadingChangesSinceLastReview = false

    private let engine: SyncEngine
    private let sendUpdateBranch: UpdateBranch
    private let sendRerun: RerunChecks
    private let fetchCandidates: FetchReviewerCandidates
    private let searchMentions: SearchMentionCandidates
    /// The pending review started here, until the comments reload with it. Keeps a failed reload from starting a second one.
    private var startedReviewID: String?
    /// The change submitting the review from this view, and its verdict.
    private var submittedReviewChange: (id: UUID, event: PullRequestReviewEvent)?
    /// How much of the discussion loads. Reloads keep what the "more" buttons added.
    private var commentLimits = PullRequestCommentLimits()
    private let cache: PullRequestCache
    private var cacheSubscription: AnyCancellable?
    private var isApplyingCacheUpdate = false
    /// The diff lines of each file changed since the last review, parsed the first time the file is shown.
    private var diffLinesSinceLastReview = LazyDiffLines()
    /// The commits `filesSinceLastReview` compares.
    private var loadedReviewRange: CommitRange?
    /// Presentations built so far, keyed by filename, scope, and whether whitespace changes are hidden.
    private var presentations: [PresentationKey: DiffPresentation] = [:]
    /// The last request for the engine to send this pull request's changes.
    private var sendTask: Task<Void, Never>?

    private struct PresentationKey: Hashable {
        let filename: String
        let scope: FileScope
        let hideWhitespace: Bool
    }

    private struct CommitRange: Equatable {
        let base: String
        let head: String
    }

    /// Loads through `engine`, and shows what it saves to the engine's cache.
    init(reference: PullRequestReference,
         engine: SyncEngine,
         updateBranch: @escaping UpdateBranch = { _, _ in },
         rerunChecks: @escaping RerunChecks = { _, _ in },
         fetchReviewerCandidates: @escaping FetchReviewerCandidates = { _, _ in [] },
         searchMentionCandidates: @escaping SearchMentionCandidates = { _, _ in [] }) {
        self.reference = reference
        self.engine = engine
        self.sendUpdateBranch = updateBranch
        self.sendRerun = rerunChecks
        self.fetchCandidates = fetchReviewerCandidates
        self.searchMentions = searchMentionCandidates
        cache = engine.cache
        pendingChanges = cache.pendingChanges(for: reference)
        if let cached = cache.shownEntry(for: reference) {
            apply(cached.content)
            commentLimits = cached.commentLimits
            checks = cached.checks
            if let changed = cached.filesSinceLastReview, let range = reviewRange {
                setFilesSinceLastReview(changed, range: range, files: cached.content.files)
            }
            if let comments = cached.comments {
                apply(comments)
            }
        }
        cacheSubscription = cache.detailUpdates.sink { [weak self] reference, entry in
            guard let self, reference == self.reference, !self.isApplyingCacheUpdate else { return }
            self.isApplyingCacheUpdate = true
            defer { self.isApplyingCacheUpdate = false }
            let pendingChanges = self.cache.pendingChanges(for: reference)
            if pendingChanges != self.pendingChanges { self.pendingChanges = pendingChanges }
            self.apply(entry.content)
            self.commentLimits = entry.commentLimits
            if let comments = entry.comments, comments != self.comments { self.apply(comments) }
            self.noteStartedReview()
            self.updateSubmittedReview()
            self.checks = entry.checks
            if let files = entry.filesSinceLastReview, let range = self.reviewRange,
               files != self.filesSinceLastReview {
                self.setFilesSinceLastReview(files, range: range, files: entry.content.files)
            }
            // While loading, `load` compares the new commits itself once the detail is in.
            if self.fileScope == .sinceLastReview, self.filesSinceLastReview == nil, !self.isLoading {
                Task { [weak self] in await self?.loadChangesSinceLastReview() }
            }
        }
    }

    /// Talks to GitHub through the monitor, which holds the token.
    convenience init(reference: PullRequestReference, monitor: PRMonitor) {
        self.init(reference: reference,
                  engine: monitor.syncEngine,
                  updateBranch: { [monitor] pullRequestID, headSHA in
                      try await monitor.updatePullRequestBranch(reference, pullRequestID: pullRequestID,
                                                                expectedHeadSHA: headSHA)
                  },
                  rerunChecks: { [monitor] rerun, repoFullName in
                      try await monitor.rerunChecks(rerun, in: repoFullName)
                  },
                  fetchReviewerCandidates: { [monitor] reference, query in
                      try await monitor.fetchReviewerCandidates(reference, query: query)
                  },
                  searchMentionCandidates: { [monitor] reference, query in
                      try await monitor.searchMentionCandidates(reference, query: query)
                  })
    }

    /// How long a pull request loaded in the background still counts as fresh when its window opens.
    static let openMaxAge: TimeInterval = 30

    /// Reloads the pull request, skipping what loaded within `maxAge`. Reloads the user asks for pass zero.
    func load(maxAge: TimeInterval = 0) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // The comments and checks load alongside the diff, which shows as soon as it arrives.
        // The detail starts first, so the comments and checks can attach to it.
        let detail = await engine.start(.detail(reference), maxAge: maxAge)
        let loadedComments = await engine.start(.comments(reference, commentLimits), maxAge: maxAge)
        let loadedChecks = await engine.start(.checks(reference), maxAge: maxAge)
        do {
            try await detail.value
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if fileScope == .sinceLastReview {
            await loadChangesSinceLastReview()
        }
        do {
            try await loadedComments.value
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            try await loadedChecks.value
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
            try await engine.request(.checks(reference))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shows loaded content. Skips identical content so a reload does not rebuild the diff.
    private func apply(_ loaded: PullRequestDetailContent) {
        guard loaded != content else { return }
        if content?.detail.headSHA != loaded.detail.headSHA { checks = nil }
        diffLines = LazyDiffLines(loaded.files)
        presentations = [:]
        viewedFiles = Set(loaded.files.filter(\.isViewed).map(\.filename))
        content = loaded
        if reviewRange != loadedReviewRange {
            filesSinceLastReview = nil
            diffLinesSinceLastReview = LazyDiffLines()
            loadedReviewRange = nil
        }
        if loaded.detail.lastReviewedSHA == nil {
            fileScope = .all
        }
    }

    /// The commits from the viewer's last review to the head, when they reviewed it.
    private var reviewRange: CommitRange? {
        guard let detail = content?.detail, let base = detail.lastReviewedSHA else { return nil }
        return CommitRange(base: base, head: detail.headSHA)
    }

    /// Whether the viewer reviewed the pull request before, so the Files tab can show only what changed since.
    var canShowChangesSinceLastReview: Bool {
        content?.detail.lastReviewedSHA != nil
    }

    /// Switches the Files tab between every change and the changes since the viewer's last review, loading those first.
    func showFiles(_ scope: FileScope) async {
        guard scope == .all || canShowChangesSinceLastReview else { return }
        fileScope = scope
        if scope == .sinceLastReview {
            await loadChangesSinceLastReview()
        }
    }

    private func loadChangesSinceLastReview() async {
        guard let range = reviewRange, let files = content?.files,
              range != loadedReviewRange, !isLoadingChangesSinceLastReview else { return }
        guard range.base != range.head else {
            // Nothing was pushed since the review.
            setFilesSinceLastReview([], range: range, files: files)
            return
        }
        isLoadingChangesSinceLastReview = true
        defer { isLoadingChangesSinceLastReview = false }
        do {
            // The changes show once the engine saves them, unless a reload moved the head meanwhile.
            try await engine.request(.changedFiles(reference, base: range.base, head: range.head))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Keeps the code owners the pull request's files already loaded, since the compare API does not return them.
    private func setFilesSinceLastReview(_ changed: [PullRequestFile], range: CommitRange, files: [PullRequestFile]) {
        let byName = Dictionary(files.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = changed.map { file in
            var file = file
            file.codeOwners = byName[file.filename]?.codeOwners ?? []
            file.isOwnedByViewer = byName[file.filename]?.isOwnedByViewer ?? false
            return file
        }
        diffLinesSinceLastReview = LazyDiffLines(changed)
        presentations = presentations.filter { $0.key.scope == .all }
        loadedReviewRange = range
        filesSinceLastReview = changed
        cache.storeChanges(changed, for: reference, baseSHA: range.base, headSHA: range.head)
    }

    /// The parsed diff lines of a file in the shown scope.
    func lines(for filename: String) -> [DiffLine]? {
        fileScope == .sinceLastReview ? diffLinesSinceLastReview.lines(for: filename) : diffLines.lines(for: filename)
    }

    private func apply(_ loaded: PullRequestComments) {
        threadIndexes = Dictionary(grouping: loaded.threads, by: \.path).mapValues(ReviewThreadIndex.init)
        comments = loaded
        startedReviewID = nil
    }

    /// Posts a comment, which shows right away as the viewer's, marked as sending, so the composer can clear.
    /// Once GitHub posts it, the comments reload and GitHub's copy takes its place. If GitHub refuses it, or may not
    /// have got it, it stays shown as failed with its text, with Retry and Discard.
    func post(_ comment: NewPullRequestComment) {
        cache.add(.comment(comment, authorLogin: viewerLogin), to: reference)
        sendPendingChanges()
    }

    /// Who the viewer is, to show their unsent comments as theirs. Nil until My PRs first loads, unless they opened
    /// this pull request.
    private var viewerLogin: String? {
        engine.cache.viewerLogin ?? content.flatMap { $0.detail.isViewerAuthor ? $0.detail.authorLogin : nil }
    }

    /// Saves a new title, description, or both, which show right away. A blank title is ignored, since GitHub
    /// requires one. If GitHub refuses, the edit stays shown as failed, with Retry and Discard.
    func edit(title: String? = nil, body: String? = nil) {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content?.detail.canEdit == true, title != nil || body != nil, title?.isEmpty != true else { return }
        if let title { cache.add(.title(title), to: reference) }
        if let body { cache.add(.body(body), to: reference) }
        sendPendingChanges()
    }

    /// Checks or unchecks a task item in the description, like clicking its box on GitHub.
    /// Saves the whole description with the box changed, so quick clicks each build on the last and the last one wins.
    func setTask(_ index: Int, checked: Bool) {
        guard let old = content?.detail.body, content?.detail.canEdit == true,
              let body = MarkdownBlocks.settingTask(index, checked: checked, in: old), body != old else { return }
        cache.add(.body(body), to: reference)
        sendPendingChanges()
    }

    /// The newest change to `field` GitHub hasn't confirmed, to show it saving or failed.
    func change(to field: PendingChange.Field) -> PendingChange? {
        pendingChanges.last { $0.kind.field == field }
    }

    /// Sends a failed change again. A change to a pending review that didn't start tries starting it again first,
    /// unless GitHub now has one, which the change joins instead, since GitHub allows one pending review at a time.
    func retry(_ change: PendingChange) {
        if case .startedBy(let startID)? = change.kind.reviewTarget,
           let start = pendingChanges.first(where: { $0.id == startID }), start.state == .failed {
            if let reviewID = cache.entry(for: reference)?.comments?.pendingReviewID {
                cache.useReview(reviewID, forChangesStartedBy: startID)
            } else {
                cache.markPending(startID)
            }
        }
        cache.markPending(change.id)
        sendPendingChanges()
    }

    /// Drops a change, putting back what GitHub last returned.
    func discard(_ change: PendingChange) {
        if change.id == submittedReviewChange?.id { submittedReviewChange = nil }
        cache.discard(change.id)
    }

    /// Changes show as soon as they're added, so the engine starts sending them afterwards.
    private func sendPendingChanges() {
        let previous = sendTask
        sendTask = Task { [engine, reference] in
            await previous?.value
            await engine.sendPendingChanges(for: reference)
        }
    }

    /// Waits until this view's changes are sent. Used by tests.
    func waitForPendingChanges() async {
        await sendTask?.value
        await engine.waitForPendingChanges()
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

    /// Where a new draft goes: the viewer's pending review, or the one a change is starting. Nil when there's none,
    /// or when starting one failed, so the next draft starts a new one.
    var pendingReviewTarget: PendingChange.ReviewTarget? {
        pendingReviewID.map { .review(id: $0) } ?? startingReview
    }

    /// The pending review the newest `startReview` change is starting or started, unless that failed, or a later
    /// change submits or discards the review.
    private var startingReview: PendingChange.ReviewTarget? {
        guard let start = pendingChanges.last(where: { change in
            guard case .startReview = change.kind else { return false }
            return change.state != .failed
        }), case .startReview(_, _, let reviewID) = start.kind else { return nil }
        let targets: [PendingChange.ReviewTarget] = [.startedBy(start.id)] + (reviewID.map { [.review(id: $0)] } ?? [])
        let isEnded = pendingChanges.contains { change in
            switch change.kind {
            case .submitPendingReview(let target, _, _, _), .discardPendingReview(let target):
                return targets.contains(target)
            default:
                return false
            }
        }
        guard !isEnded else { return nil }
        return reviewID.map { .review(id: $0) } ?? .startedBy(start.id)
    }

    /// Draft comments waiting in the pending review.
    var pendingCommentCount: Int {
        comments?.pendingCommentCount ?? 0
    }

    /// Submits a review of the head commit that was loaded, publishing any draft comments with it. It shows right
    /// away in the Activity list, and as the verdict above it, so the form can close. If GitHub refuses it, it stays
    /// in the list as failed, with its text, Retry and Discard.
    func submitReview(_ event: PullRequestReviewEvent, body: String) {
        guard canReview, let commitID = content?.detail.headSHA else { return }
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ReviewComposer.canSubmit(event, text: body, pendingCommentCount: pendingCommentCount) else { return }
        let change: PendingChange
        if let target = pendingReviewTarget {
            change = cache.add(.submitPendingReview(review: target, event: event, body: body, authorLogin: viewerLogin),
                               to: reference)
        } else {
            change = cache.add(.review(NewPullRequestReview(event: event, body: body, commitID: commitID),
                                       authorLogin: viewerLogin), to: reference)
        }
        startedReviewID = nil
        submittedReviewChange = (change.id, event)
        updateSubmittedReview()
        sendPendingChanges()
    }

    /// Discards the pending review and its draft comments, which disappear right away. If GitHub refuses, the error
    /// shows above the conversation, with Retry and Discard.
    func discardPendingReview() {
        guard let target = pendingReviewTarget else { return }
        startedReviewID = nil
        if case .startedBy(let startID) = target,
           let start = pendingChanges.first(where: { $0.id == startID }), start.state == .pending {
            // GitHub wasn't asked to start it yet, so dropping it and its drafts here is enough.
            cache.discardReview(startedBy: startID)
            return
        }
        cache.add(.discardPendingReview(review: target), to: reference)
        sendPendingChanges()
    }

    /// Adds a draft comment to the pending review, starting one on the loaded head commit if there is none yet. The
    /// draft shows right away in its place, marked as pending, so the composer can clear. The engine sends the start
    /// first and passes the review it started to the draft.
    func addToReview(_ comment: PendingReviewComment) {
        guard canReview, let detail = content?.detail else { return }
        let target = pendingReviewTarget ?? .startedBy(
            cache.add(.startReview(pullRequestID: detail.nodeID, commitID: detail.headSHA, reviewID: nil),
                      to: reference).id)
        cache.add(.reviewComment(comment, review: target, authorLogin: viewerLogin), to: reference)
        sendPendingChanges()
    }

    /// Keeps the review this view started until the comments reload with it, so a failed reload doesn't start a
    /// second one.
    private func noteStartedReview() {
        if comments?.pendingReviewID == nil, case .review(let reviewID)? = startingReview {
            startedReviewID = reviewID
        }
    }

    /// Shows the verdict of the review submitted here, unless GitHub refused it.
    private func updateSubmittedReview() {
        guard let submitted = submittedReviewChange else {
            submittedReview = nil
            return
        }
        let change = pendingChanges.first { $0.id == submitted.id }
        let event = change?.state == .failed ? nil : submitted.event
        if event != submittedReview { submittedReview = event }
    }

    /// Discards of the pending review GitHub refused, to show with Retry and Discard.
    var failedReviewDiscards: [PendingChange] {
        pendingChanges.filter { change in
            guard change.state == .failed, case .discardPendingReview = change.kind else { return false }
            return true
        }
    }

    func reviewerCandidates(matching query: String) async throws -> [ReviewerCandidate] {
        try await fetchCandidates(reference, query)
    }

    func mentionCandidates(matching query: String) async throws -> [MentionCandidate] {
        try await searchMentions(reference, query)
    }

    /// Requests a review from a user or team, or removes their request, like toggling them in GitHub's reviewer picker.
    /// Shows the change right away; once GitHub accepts it, the detail reloads for GitHub's own view of the reviewers.
    func setReviewRequested(_ name: String, kind: PullRequestReviewer.Kind, requested: Bool) {
        guard content?.detail.canRequestReviewers == true else { return }
        cache.add(.reviewRequested(name: name, kind: kind, requested: requested), to: reference)
        sendPendingChanges()
    }

    /// Reviewers whose request is being added or removed, by `PullRequestReviewer.id`.
    var reviewRequestsInFlight: Set<String> {
        Set(pendingChanges.compactMap { change in
            guard change.state != .failed, case .reviewRequested(let id)? = change.kind.field else { return nil }
            return id
        })
    }

    /// Review requests GitHub refused, oldest first.
    var failedReviewRequests: [PendingChange] {
        pendingChanges.filter { change in
            guard change.state == .failed, case .reviewRequested = change.kind else { return false }
            return true
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

    /// Updates the cached copy from GitHub, so pending changes stay on top of it rather than saved into it.
    private func setCanUpdateBranch(_ canUpdateBranch: Bool) {
        guard let current = cache.entry(for: reference)?.content else { return }
        var detail = current.detail
        detail.canUpdateBranch = canUpdateBranch
        cache.store(PullRequestDetailContent(detail: detail, files: current.files))
    }

    /// Whether new comments on the diff join the pending review instead of posting right away, like on GitHub once a review is started.
    var isReviewPending: Bool {
        canReview && pendingReviewTarget != nil
    }

    /// Posts a new review thread on a diff line, against the head commit that was loaded, which shows right away.
    /// Joins the pending review instead when one is started.
    func postInlineComment(_ body: String, at anchor: DiffCommentAnchor) {
        if isReviewPending {
            addToReview(.thread(body: body, anchor: anchor))
            return
        }
        guard let commitID = content?.detail.headSHA else { return }
        post(.inline(body: body, commitID: commitID, anchor: anchor))
    }

    /// Replies to a thread, which shows right away, or as a draft in the pending review when one is started.
    func reply(_ body: String, to thread: ReviewThread) {
        if isReviewPending {
            addToReview(.reply(body: body, threadID: thread.id))
            return
        }
        guard let first = thread.comments.first else { return }
        post(.reply(body: body, commentID: first.databaseID))
    }

    /// Resolves or unresolves a review thread, which shows right away. Once GitHub accepts it, the comments reload.
    func setResolved(_ resolved: Bool, thread: ReviewThread) {
        let current = comments?.threads.first { $0.id == thread.id } ?? thread
        guard current.isResolved != resolved else { return }
        cache.add(.threadResolved(threadID: thread.id, resolved: resolved), to: reference)
        sendPendingChanges()
    }

    func threadIndex(for filename: String) -> ReviewThreadIndex {
        threadIndexes[filename] ?? ReviewThreadIndex(threads: [])
    }

    /// Loads the next older general comments, which show above the ones loaded.
    func loadEarlierComments() async {
        await loadMoreComments(commentLimits.addingEarlierComments())
    }

    /// Loads the next review threads, which show on the diff like the ones loaded.
    func loadMoreThreads() async {
        await loadMoreComments(commentLimits.addingThreads())
    }

    private func loadMoreComments(_ limits: PullRequestCommentLimits) async {
        guard !isLoadingMoreComments else { return }
        isLoadingMoreComments = true
        defer { isLoadingMoreComments = false }
        do {
            // The cache keeps the new limits with the comments, and reloads use them from then on.
            try await engine.request(.comments(reference, limits))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The file's diff in the shown scope with word highlights, built on first use and then reused.
    func presentation(for filename: String, hideWhitespace: Bool) -> DiffPresentation {
        let key = PresentationKey(filename: filename, scope: fileScope, hideWhitespace: hideWhitespace)
        if let cached = presentations[key] { return cached }
        let presentation = DiffPresentation(lines: lines(for: filename) ?? [], hideWhitespace: hideWhitespace,
                                            language: SyntaxLanguage(filename: filename))
        presentations[key] = presentation
        return presentation
    }

    /// Updates the viewed mark right away and syncs it to GitHub. If GitHub refuses, the mark stays shown as failed.
    func setViewed(_ viewed: Bool, filename: String) {
        guard let pullRequestID = content?.detail.nodeID, viewedFiles.contains(filename) != viewed else { return }
        cache.add(.fileViewed(pullRequestID: pullRequestID, path: filename, viewed: viewed), to: reference)
        sendPendingChanges()
    }
}
