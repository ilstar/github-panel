import Foundation

#if DEBUG
final class MockGitHubAPI: GitHubAPIClient {
    private let user = GitHubUser(login: "mock-user")
    private var pullRequests: [String: PullRequestRow]
    private let history: [PullRequestHistoryRow]

    init(now: Date = Date(), isEmpty: Bool = false) {
        let rows = isEmpty ? [] : Self.makePullRequests().map {
            $0.copy(updatedAt: now.addingTimeInterval(TimeInterval(-$0.number * 70)))
        }
        self.pullRequests = Dictionary(uniqueKeysWithValues: rows.map { ("\($0.repoFullName)#\($0.number)", $0) })
        self.history = isEmpty ? [] : Self.makeHistory(now: now)
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
        let title = pullRequests[reference.id]?.title
            ?? history.first { $0.id == reference.id }?.title
            ?? "Mock pull request"
        let isDraft = pullRequests[reference.id]?.isDraft ?? false
        let detail = PullRequestDetail(reference: reference,
                                       title: title,
                                       body: Self.detailBody,
                                       authorLogin: user.login,
                                       state: isDraft ? .draft : .open,
                                       baseRef: "main",
                                       headRef: "mock-user/pr-\(reference.number)",
                                       htmlURL: URL(string: "https://github.com/\(reference.repoFullName)/pull/\(reference.number)")!,
                                       createdAt: Date(timeIntervalSinceNow: -3 * 86_400),
                                       additions: Self.detailFiles.reduce(0) { $0 + $1.additions },
                                       deletions: Self.detailFiles.reduce(0) { $0 + $1.deletions },
                                       changedFiles: Self.detailFiles.count,
                                       commits: 3)
        return PullRequestDetailContent(detail: detail, files: Self.detailFiles)
    }

    private static let detailBody = """
    ## Summary

    - Adds a **detail window** for pull requests.
    - Renders the description and the `diff` of each changed file.

    ## Tests

    - Added parser tests. See [the plan](https://github.com/mock/github-panel) for more.
    """

    private static let detailFiles: [PullRequestFile] = [
        PullRequestFile(filename: "Sources/Widget.swift",
                        previousFilename: nil,
                        status: .modified,
                        additions: 3,
                        deletions: 1,
                        patch: """
                        @@ -10,6 +10,8 @@ struct Widget {
                             let name: String
                        -    let size: Int
                        +    let width: Int
                        +    let height: Int
                             let color: Color
                        +    let isEnabled: Bool
                         
                             var description: String {
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
        PullRequestFile(filename: "Resources/logo.png",
                        previousFilename: nil,
                        status: .added,
                        additions: 0,
                        deletions: 0,
                        patch: nil)
    ]

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
    func copy(isDraft: Bool? = nil,
              isAutoMergeEnabled: Bool? = nil,
              canEnableAutoMerge: Bool? = nil,
              canDisableAutoMerge: Bool? = nil,
              isInMergeQueue: Bool? = nil,
              mergeStateStatus: String? = nil,
              updatedAt: Date? = nil) -> PullRequestRow {
        PullRequestRow(id: id,
                         nodeID: nodeID,
                        title: title,
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
