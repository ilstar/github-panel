import Foundation
@testable import GithubPanel

extension PullRequestDetailViewModel {
    /// A view model whose sync engine loads from and sends to the given closures, as GitHub would answer them.
    /// Without a cache, it gets one of its own.
    convenience init(reference: PullRequestReference,
                     fetch: @escaping (PullRequestReference) async throws -> PullRequestDetailContent,
                     fetchChangedFiles: @escaping (String, String, String) async throws -> [PullRequestFile] = { _, _, _ in [] },
                     setViewed: @escaping (String, String, Bool) async throws -> Void = { _, _, _ in },
                     fetchComments: @escaping (PullRequestReference, PullRequestCommentLimits) async throws
                         -> PullRequestComments = { _, _ in .empty },
                     postComment: ((NewPullRequestComment, PullRequestReference) async throws -> Int)? = nil,
                     setResolved: @escaping (String, Bool) async throws -> Void = { _, _ in },
                     edit: @escaping (PullRequestReference, String?, String?) async throws -> Void = { _, _, _ in },
                     submitReview: ((NewPullRequestReview, PullRequestReference) async throws -> Int)? = nil,
                     updateBranch: @escaping UpdateBranch = { _, _ in },
                     startPendingReview: ((String, String) async throws -> String)? = nil,
                     addPendingComment: ((PendingReviewComment, String) async throws -> Int?)? = nil,
                     submitPendingReview: ((String, PullRequestReviewEvent, String) async throws -> Int?)? = nil,
                     deletePendingReview: ((String) async throws -> Void)? = nil,
                     fetchChecks: @escaping (PullRequestReference) async throws -> PullRequestChecks = { _ in .empty },
                     rerunChecks: @escaping RerunChecks = { _, _ in },
                     fetchReviewerCandidates: @escaping FetchReviewerCandidates = { _, _ in [] },
                     setReviewRequested: @escaping (PullRequestReference, String, PullRequestReviewer.Kind, Bool)
                         async throws -> Void = { _, _, _, _ in },
                     searchMentionCandidates: @escaping SearchMentionCandidates = { _, _ in [] },
                     viewerLogin: String? = nil,
                     cache: PullRequestDetailCache? = nil) {
        let api = FakeGitHubAPI()
        api.detailHandler = fetch
        api.changedFilesHandler = fetchChangedFiles
        api.commentsHandler = fetchComments
        api.checksHandler = fetchChecks
        api.setFileViewedHandler = setViewed
        api.setResolvedHandler = setResolved
        api.editHandler = edit
        api.setReviewRequestedHandler = setReviewRequested
        api.postCommentHandler = postComment
        api.reviewHandler = submitReview
        api.startPendingReviewHandler = startPendingReview
        api.pendingCommentHandler = addPendingComment
        api.submitPendingReviewHandler = submitPendingReview
        api.deletePendingReviewHandler = deletePendingReview
        let session = UUID()
        let lists = PullRequestListCache()
        lists.viewerLogin = viewerLogin
        let engine = SyncEngine(api: api, store: .inMemory(), cache: cache ?? PullRequestDetailCache(),
                                lists: lists) {
            SyncEngine.Credential(token: "token", session: session)
        }
        self.init(reference: reference, engine: engine, updateBranch: updateBranch,
                  rerunChecks: rerunChecks, fetchReviewerCandidates: fetchReviewerCandidates,
                  searchMentionCandidates: searchMentionCandidates)
    }
}
