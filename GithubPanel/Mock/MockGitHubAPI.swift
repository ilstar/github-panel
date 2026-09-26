import Foundation

#if DEBUG
final class MockGitHubAPI: GitHubAPIClient {
    private let user = GitHubUser(login: "mock-user")
    private var pullRequests: [String: PullRequestRow]
    private let history: [PullRequestHistoryRow]
    private let reviewRequests: ReviewRequests
    /// Viewed file paths, keyed by pull request node ID.
    private var viewedFiles: [String: Set<String>] = [:]
    /// Comments, keyed by pull request reference ID. Filled with fixtures on first read.
    private var comments: [String: PullRequestComments] = [:]
    private var nextCommentID = 1_000
    /// Edited titles and descriptions, keyed by pull request reference ID.
    private var editedTitles: [String: String] = [:]
    private var editedBodies: [String: String] = [:]

    init(now: Date = Date(), isEmpty: Bool = false) {
        let rows = isEmpty ? [] : Self.makePullRequests().map {
            $0.copy(updatedAt: now.addingTimeInterval(TimeInterval(-$0.number * 70)))
        }
        self.pullRequests = Dictionary(uniqueKeysWithValues: rows.map { ("\($0.repoFullName)#\($0.number)", $0) })
        self.history = isEmpty ? [] : Self.makeHistory(now: now)
        self.reviewRequests = isEmpty ? .empty : Self.makeReviewRequests(now: now)
    }

    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        user
    }

    func fetchOpenPRs(token: String) async throws -> OpenPullRequests {
        let rows = pullRequests.values.sorted { $0.updatedAt > $1.updatedAt }
        return OpenPullRequests(login: user.login, rows: Array(rows.prefix(10)))
    }

    func fetchClosedPRs(token: String, username: String, page: Int, perPage: Int) async throws -> PullRequestHistoryPage {
        let safePage = max(1, page)
        let safePerPage = max(1, perPage)
        let start = (safePage - 1) * safePerPage
        let rows = start >= history.count ? [] : Array(history.dropFirst(start).prefix(safePerPage))
        return PullRequestHistoryPage(rows: rows,
                                      page: safePage,
                                      perPage: safePerPage,
                                      totalCount: history.count)
    }

    func fetchReviewRequests(token: String) async throws -> ReviewRequests {
        reviewRequests
    }

    func enqueuePullRequest(token: String, pullRequestID: String) async throws {
        updatePullRequest(with: pullRequestID) { pr in
            pr.copy(isInMergeQueue: true, mergeStateStatus: "QUEUED")
        }
    }

    func markPullRequestReadyForReview(token: String, pullRequestID: String) async throws {
        updatePullRequest(with: pullRequestID) { pr in
            pr.copy(isDraft: false)
        }
    }

    func enableAutoMerge(token: String, pullRequestID: String) async throws {
        updatePullRequest(with: pullRequestID) { pr in
            pr.copy(isAutoMergeEnabled: true, canEnableAutoMerge: false, canDisableAutoMerge: true)
        }
    }

    func disableAutoMerge(token: String, pullRequestID: String) async throws {
        updatePullRequest(with: pullRequestID) { pr in
            pr.copy(isAutoMergeEnabled: false, canEnableAutoMerge: true, canDisableAutoMerge: false)
        }
    }

    func mergePullRequest(token: String, repoFullName: String, number: Int) async throws -> Bool {
        pullRequests.removeValue(forKey: "\(repoFullName)#\(number)")
        return true
    }

    func fetchPullRequestDetail(token: String, reference: PullRequestReference) async throws -> PullRequestDetailContent {
        let title = editedTitles[reference.id]
            ?? pullRequests[reference.id]?.title
            ?? history.first { $0.id == reference.id }?.title
            ?? reviewRequests.rows.first { $0.id == reference.id }?.title
            ?? "Mock pull request"
        let isDraft = pullRequests[reference.id]?.isDraft ?? false
        let nodeID = "mock-detail-\(reference.id)"
        // Review requests were opened by someone else, so only those stay read-only.
        let reviewAuthor = reviewRequests.rows.first { $0.id == reference.id }?.authorLogin
        let isOwn = pullRequests[reference.id] != nil || reviewAuthor == nil
        let authorLogin = isOwn ? user.login : reviewAuthor ?? user.login
        let detail = PullRequestDetail(reference: reference,
                                       nodeID: nodeID,
                                       title: title,
                                       body: editedBodies[reference.id] ?? Self.detailBody,
                                       authorLogin: authorLogin,
                                       state: isDraft ? .draft : .open,
                                       baseRef: "main",
                                       headRef: "mock-user/pr-\(reference.number)",
                                       headSHA: "mock-sha-\(reference.number)",
                                       htmlURL: URL(string: "https://github.com/\(reference.repoFullName)/pull/\(reference.number)")!,
                                       createdAt: Date(timeIntervalSinceNow: -3 * 86_400),
                                       additions: Self.detailFiles.reduce(0) { $0 + $1.additions },
                                       deletions: Self.detailFiles.reduce(0) { $0 + $1.deletions },
                                       changedFiles: Self.detailFiles.count,
                                       commits: 3,
                                       canEdit: isOwn,
                                       updatedAt: pullRequests[reference.id]?.updatedAt)
        let viewed = viewedFiles[nodeID] ?? []
        let files = Self.detailFiles.map { file in
            var file = file
            file.isViewed = viewed.contains(file.filename)
            return file
        }
        return PullRequestDetailContent(detail: detail, files: files)
    }

    func setFileViewed(token: String, pullRequestID: String, path: String, viewed: Bool) async throws {
        if viewed {
            viewedFiles[pullRequestID, default: []].insert(path)
        } else {
            viewedFiles[pullRequestID]?.remove(path)
        }
    }

    func fetchPullRequestComments(token: String, reference: PullRequestReference) async throws -> PullRequestComments {
        if let stored = comments[reference.id] { return stored }
        let fixtures = Self.makeComments(now: Date())
        comments[reference.id] = fixtures
        return fixtures
    }

    func postPullRequestComment(token: String, reference: PullRequestReference, comment: NewPullRequestComment) async throws {
        let current = try await fetchPullRequestComments(token: token, reference: reference)
        nextCommentID += 1
        func makeComment(_ body: String) -> PullRequestComment {
            PullRequestComment(id: "mock-comment-\(nextCommentID)", databaseID: nextCommentID, authorLogin: user.login,
                               body: body, createdAt: Date(), htmlURL: nil)
        }
        switch comment {
        case let .general(body):
            comments[reference.id] = PullRequestComments(comments: current.comments + [makeComment(body)],
                                                         threads: current.threads)
        case let .inline(body, _, anchor):
            let thread = ReviewThread(id: "mock-thread-\(nextCommentID)", path: anchor.path, line: anchor.line,
                                      startLine: nil, side: anchor.side, isResolved: false, isOutdated: false,
                                      comments: [makeComment(body)])
            comments[reference.id] = PullRequestComments(comments: current.comments, threads: current.threads + [thread])
        case let .reply(body, commentID):
            let threads = current.threads.map { thread in
                guard thread.comments.first?.databaseID == commentID else { return thread }
                return ReviewThread(id: thread.id, path: thread.path, line: thread.line, startLine: thread.startLine,
                                    side: thread.side, isResolved: thread.isResolved, isOutdated: thread.isOutdated,
                                    comments: thread.comments + [makeComment(body)])
            }
            comments[reference.id] = PullRequestComments(comments: current.comments, threads: threads)
        }
    }

    private static func makeComments(now: Date) -> PullRequestComments {
        func comment(_ id: Int, _ author: String, _ body: String, hoursAgo: Double) -> PullRequestComment {
            PullRequestComment(id: "mock-comment-\(id)", databaseID: id, authorLogin: author, body: body,
                               createdAt: now.addingTimeInterval(-hoursAgo * 3_600), htmlURL: nil)
        }
        return PullRequestComments(
            comments: [
                comment(1, "octocat", "Thanks for splitting this up — much easier to review.", hoursAgo: 30),
                comment(2, "mock-user", "Happy to. I'll follow up with the **settings** change separately.", hoursAgo: 28)
            ],
            threads: [
                ReviewThread(id: "mock-thread-1", path: "Sources/Widget.swift", line: 12, startLine: nil,
                             side: .right, isResolved: false, isOutdated: false,
                             comments: [
                                 comment(3, "hubot", "Should `height` default to `width` for square widgets?", hoursAgo: 20),
                                 comment(4, "mock-user", "Good call, I'll add an initializer for that.", hoursAgo: 19)
                             ]),
                ReviewThread(id: "mock-thread-2", path: "Sources/Widget.swift", line: 23, startLine: nil,
                             side: .left, isResolved: true, isOutdated: false,
                             comments: [comment(5, "octocat", "Nit: keep the old greeting in the changelog.", hoursAgo: 18)]),
                ReviewThread(id: "mock-thread-3", path: "Sources/Legacy.swift", line: nil, startLine: nil,
                             side: .right, isResolved: false, isOutdated: true,
                             comments: [comment(6, "monalisa", "Is anything still importing this?", hoursAgo: 40)])
            ]
        )
    }

    private static let detailBody = """
    ## Summary

    - Adds a **detail window** for pull requests.
    - Renders the description and the `diff` of each changed file.

    <!-- Template hint: this comment is hidden. -->

    ## Tests

    1. Added parser tests.
    2. See [the plan](https://github.com/mock/github-panel) for more.

    ```swift
    let lines = DiffParser.parse(patch)
    ```

    > Mock data for `mise run mock`.
    """

    private static let detailFiles: [PullRequestFile] = [
        PullRequestFile(filename: "Sources/Widget.swift",
                        previousFilename: nil,
                        status: .modified,
                        additions: 6,
                        deletions: 4,
                        patch: """
                        @@ -10,6 +10,8 @@ struct Widget {
                             let name: String
                        -    let size: Int
                        +    let width: Int
                        +    let height: Int
                             let color: Color
                        +    let isEnabled: Bool
                         
                             var description: String {
                        @@ -20,6 +22,6 @@ struct Widget {
                             func greet() -> String {
                        -        return "hello world"
                        +        return "hello claude"
                             }
                        -  func reset() {
                        -    size = 0
                        +    func reset() {
                        +        size = 0
                             }
                        """),
        PullRequestFile(filename: "Sources/WidgetView.swift",
                        previousFilename: nil,
                        status: .added,
                        additions: 5,
                        deletions: 0,
                        patch: """
                        @@ -0,0 +1,5 @@
                        +import SwiftUI
                        +
                        +struct WidgetView: View {
                        +    var body: some View { Text("Widget") }
                        +}
                        """),
        PullRequestFile(filename: "Sources/Legacy.swift",
                        previousFilename: nil,
                        status: .removed,
                        additions: 0,
                        deletions: 2,
                        patch: """
                        @@ -1,2 +0,0 @@
                        -// Old code
                        -struct Legacy {}
                        """),
        PullRequestFile(filename: "Sources/Settings/Panels/General.swift",
                        previousFilename: nil,
                        status: .modified,
                        additions: 1,
                        deletions: 1,
                        patch: """
                        @@ -3,3 +3,3 @@ struct GeneralPanel: View {
                             var body: some View {
                        -        Toggle("Launch at login", isOn: $launchAtLogin)
                        +        Toggle("Open at login", isOn: $launchAtLogin)
                             }
                        """),
        PullRequestFile(filename: "Resources/logo.png",
                        previousFilename: nil,
                        status: .added,
                        additions: 0,
                        deletions: 0,
                        patch: nil)
    ]

    func editPullRequest(token: String, reference: PullRequestReference, title: String?, body: String?) async throws {
        if let body {
            editedBodies[reference.id] = body
        }
        guard let title else { return }
        editedTitles[reference.id] = title
        if let row = pullRequests[reference.id] {
            pullRequests[reference.id] = row.copy(title: title)
        }
    }

    private func updatePullRequest(with nodeID: String, transform: (PullRequestRow) -> PullRequestRow) {
        guard let match = pullRequests.first(where: { $0.value.nodeID == nodeID }) else { return }
        pullRequests[match.key] = transform(match.value)
    }

    private static func makePullRequests() -> [PullRequestRow] {
        [
            pullRequest(number: 101,
                        title: "Ready: merge button",
                        status: .success),
            pullRequest(number: 102,
                        title: "Pending: enable auto-merge",
                        status: .pending,
                        canEnableAutoMerge: true),
            pullRequest(number: 103,
                        title: "Pending: disable auto-merge",
                        status: .pending,
                        isAutoMergeEnabled: true,
                        canDisableAutoMerge: true),
            pullRequest(number: 104,
                        title: "Ready: merge queue enabled",
                        status: .success,
                        isMergeQueueEnabled: true,
                        mergeStateStatus: "CLEAN"),
            pullRequest(number: 105,
                        title: "Already in merge queue",
                        status: .success,
                        isMergeQueueEnabled: true,
                        isInMergeQueue: true,
                        mergeStateStatus: "QUEUED"),
            pullRequest(number: 106,
                        title: "Checks failed",
                        status: .failure,
                        mergeStateStatus: "DIRTY"),
            pullRequest(number: 107,
                        title: "Checks errored",
                        status: .error,
                        mergeStateStatus: "BLOCKED"),
            pullRequest(number: 108,
                        title: "Waiting: auto-merge unavailable",
                        status: .pending),
            pullRequest(number: 109,
                        title: "Draft: success but not mergeable",
                        status: .success,
                        isDraft: true),
            pullRequest(number: 110,
                        title: "Unknown check state",
                        status: .unknown),
            pullRequest(number: 111,
                        title: "Ready: no checks, add to queue",
                        status: .noChecks,
                        isMergeQueueEnabled: true)
        ]
    }

    private static func makeHistory(now: Date) -> [PullRequestHistoryRow] {
        (1...24).map { index in
            let number = 200 - index
            let mergedAt = index % 4 == 0 ? nil : now.addingTimeInterval(TimeInterval(-index * 86_400))
            let closedAt = mergedAt ?? now.addingTimeInterval(TimeInterval(-index * 86_400))
            return PullRequestHistoryRow(id: "mock/github-panel#\(number)",
                                         title: index % 4 == 0 ? "Closed: explored alternate flow \(number)" : "Merged: shipped update \(number)",
                                         number: number,
                                         repoFullName: "mock/github-panel",
                                         htmlURL: URL(string: "https://github.com/mock/github-panel/pull/\(number)")!,
                                         updatedAt: closedAt,
                                         closedAt: closedAt,
                                         mergedAt: mergedAt)
        }
    }

    private static func makeReviewRequests(now: Date) -> ReviewRequests {
        func request(number: Int, title: String, author: String, isDraft: Bool = false) -> ReviewRequestRow {
            ReviewRequestRow(id: "mock/github-panel#\(number)",
                             title: title,
                             number: number,
                             repoFullName: "mock/github-panel",
                             htmlURL: URL(string: "https://github.com/mock/github-panel/pull/\(number)")!,
                             authorLogin: author,
                             isDraft: isDraft,
                             updatedAt: now.addingTimeInterval(TimeInterval(-(number - 300) * 3_600)))
        }
        return ReviewRequests(fromMe: [
            request(number: 301, title: "Review: tidy the settings window", author: "octocat"),
            request(number: 302, title: "Review: faster diff parsing", author: "hubot")
        ], fromMyTeams: [
            request(number: 303, title: "Team review: rename the release task", author: "monalisa"),
            request(number: 304, title: "Team review: draft icon refresh", author: "octocat", isDraft: true)
        ])
    }

    private static func pullRequest(number: Int,
                                    title: String,
                                    status: CheckState,
                                    isDraft: Bool = false,
                                    isAutoMergeEnabled: Bool = false,
                                    canEnableAutoMerge: Bool = false,
                                    canDisableAutoMerge: Bool = false,
                                    isMergeQueueEnabled: Bool = false,
                                    isInMergeQueue: Bool = false,
                                    mergeStateStatus: String = "CLEAN") -> PullRequestRow {
        PullRequestRow(id: "mock/github-panel#\(number)",
                        nodeID: "mock-node-\(number)",
                        title: title,
                        number: number,
                        repoFullName: "mock/github-panel",
                        htmlURL: URL(string: "https://github.com/mock/github-panel/pull/\(number)")!,
                        headSHA: "mock-sha-\(number)",
                        status: status,
                        isDraft: isDraft,
                        isAutoMergeEnabled: isAutoMergeEnabled,
                        canEnableAutoMerge: canEnableAutoMerge,
                        canDisableAutoMerge: canDisableAutoMerge,
                        isMergeQueueEnabled: isMergeQueueEnabled,
                        isInMergeQueue: isInMergeQueue,
                        mergeStateStatus: mergeStateStatus,
                        updatedAt: Date(timeIntervalSince1970: 0))
    }
}

private extension PullRequestRow {
    func copy(title: String? = nil,
              isDraft: Bool? = nil,
              isAutoMergeEnabled: Bool? = nil,
              canEnableAutoMerge: Bool? = nil,
              canDisableAutoMerge: Bool? = nil,
              isInMergeQueue: Bool? = nil,
              mergeStateStatus: String? = nil,
              updatedAt: Date? = nil) -> PullRequestRow {
        PullRequestRow(id: id,
                         nodeID: nodeID,
                        title: title ?? self.title,
                        number: number,
                        repoFullName: repoFullName,
                        htmlURL: htmlURL,
                        headSHA: headSHA,
                        status: status,
                        isDraft: isDraft ?? self.isDraft,
                        isAutoMergeEnabled: isAutoMergeEnabled ?? self.isAutoMergeEnabled,
                        canEnableAutoMerge: canEnableAutoMerge ?? self.canEnableAutoMerge,
                        canDisableAutoMerge: canDisableAutoMerge ?? self.canDisableAutoMerge,
                        isMergeQueueEnabled: isMergeQueueEnabled,
                        isInMergeQueue: isInMergeQueue ?? self.isInMergeQueue,
                        mergeStateStatus: mergeStateStatus ?? self.mergeStateStatus,
                        updatedAt: updatedAt ?? self.updatedAt)
    }
}
#endif
