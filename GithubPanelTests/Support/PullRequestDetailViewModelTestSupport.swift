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
                     postComment: @escaping PostComment = { _, _ in },
                     setResolved: @escaping (String, Bool) async throws -> Void = { _, _ in },
                     edit: @escaping (PullRequestReference, String?, String?) async throws -> Void = { _, _, _ in },
                     submitReview: @escaping SubmitReview = { _, _ in },
                     updateBranch: @escaping UpdateBranch = { _, _ in },
                     startPendingReview: @escaping StartPendingReview = { _, _ in "" },
                     addPendingComment: @escaping AddPendingComment = { _, _ in },
                     submitPendingReview: @escaping SubmitPendingReview = { _, _, _ in },
                     deletePendingReview: @escaping DeletePendingReview = { _ in },
                     fetchChecks: @escaping (PullRequestReference) async throws -> PullRequestChecks = { _ in .empty },
                     rerunChecks: @escaping RerunChecks = { _, _ in },
                     fetchReviewerCandidates: @escaping FetchReviewerCandidates = { _, _ in [] },
                     setReviewRequested: @escaping (PullRequestReference, String, PullRequestReviewer.Kind, Bool)
                         async throws -> Void = { _, _, _, _ in },
                     searchMentionCandidates: @escaping SearchMentionCandidates = { _, _ in [] },
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
        let session = UUID()
        let engine = SyncEngine(api: api, store: .inMemory(), cache: cache ?? PullRequestDetailCache(),
                                lists: PullRequestListCache()) {
            SyncEngine.Credential(token: "token", session: session)
        }
        self.init(reference: reference, engine: engine, postComment: postComment,
                  submitReview: submitReview, updateBranch: updateBranch,
                  startPendingReview: startPendingReview, addPendingComment: addPendingComment,
                  submitPendingReview: submitPendingReview, deletePendingReview: deletePendingReview,
                  rerunChecks: rerunChecks, fetchReviewerCandidates: fetchReviewerCandidates,
                  searchMentionCandidates: searchMentionCandidates)
    }
}
