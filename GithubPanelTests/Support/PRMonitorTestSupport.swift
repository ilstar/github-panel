import Foundation
import XCTest
@testable import GithubPanel

@MainActor
func makeMonitor(api: FakeGitHubAPI = FakeGitHubAPI(),
                         tokenStore: FakeTokenStore = FakeTokenStore(token: nil),
                         notificationPoster: FakeNotificationPoster = FakeNotificationPoster(),
                         defaults: FakeDefaults = FakeDefaults(),
                         timerScheduler: FakeTimerScheduler = FakeTimerScheduler(),
                         dateProvider: FakeDateProvider = FakeDateProvider(now: Date(timeIntervalSince1970: 0)),
                         hookRunner: FakeHookRunner = FakeHookRunner()) -> PRMonitor {
    PRMonitor(api: api,
              tokenStore: tokenStore,
              notificationPoster: notificationPoster,
              defaults: defaults,
              timerScheduler: timerScheduler,
              dateProvider: dateProvider,
              hookRunner: hookRunner)
}

final class FakeGitHubAPI: GitHubAPIClient {
    var user = GitHubUser(login: "fred")
    var rows: [PullRequestRow] = []
    var historyPages: [Int: PullRequestHistoryPage] = [:]
    var reviewRequests: ReviewRequests = .empty
    var reviewRequestsHandler: ((String) async throws -> ReviewRequests)?
    private(set) var fetchReviewRequestsTokens: [String] = []
    var error: Error?
    var mergeResult = true

    private(set) var fetchCurrentUserTokens: [String] = []
    var openHandler: ((String) async throws -> OpenPullRequests)?
    var userHandler: ((String) async throws -> GitHubUser)?
    var historyHandler: ((String, String, Int, Int) async throws -> PullRequestHistoryPage)?
    private(set) var historyUsernames: [String] = []
    private(set) var fetchOpenPRTokens: [String] = []
    private(set) var fetchClosedPRCalls: [(page: Int, perPage: Int)] = []
    private(set) var enqueueCalls: [String] = []
    private(set) var markReadyCalls: [String] = []
    private(set) var enableCalls: [String] = []
    private(set) var disableCalls: [String] = []
    private(set) var mergePullRequestCalls: [(repoFullName: String, number: Int)] = []
    private(set) var detailCalls: [(token: String, reference: PullRequestReference)] = []
    var detailHandler: ((PullRequestReference) async throws -> PullRequestDetailContent)?
    private(set) var setFileViewedCalls: [(token: String, pullRequestID: String, path: String, viewed: Bool)] = []
    var comments: PullRequestComments = .empty
    private(set) var commentsCalls: [(token: String, reference: PullRequestReference)] = []
    private(set) var postCommentCalls: [(token: String, reference: PullRequestReference, comment: NewPullRequestComment)] = []
    private(set) var editCalls: [(token: String, reference: PullRequestReference, title: String?, body: String?)] = []
    var enableHandler: ((String) async -> Void)?
    var enqueueHandler: ((String) async -> Void)?

    func fetchCurrentUser(token: String) async throws -> GitHubUser {
        if let error { throw error }
        fetchCurrentUserTokens.append(token)
        if let userHandler { return try await userHandler(token) }
        return user
    }

    func fetchOpenPRs(token: String) async throws -> OpenPullRequests {
        fetchOpenPRTokens.append(token)
        if let openHandler { return try await openHandler(token) }
        if let error { throw error }
        return OpenPullRequests(login: user.login,
                                rows: rows)
    }

    func fetchClosedPRs(token: String, username: String, page: Int, perPage: Int) async throws -> PullRequestHistoryPage {
        if let error { throw error }
        historyUsernames.append(username)
        fetchClosedPRCalls.append((page, perPage))
        if let historyHandler { return try await historyHandler(token, username, page, perPage) }
        return historyPages[page] ?? PullRequestHistoryPage(rows: [],
                                                            page: page,
                                                            perPage: perPage,
                                                            totalCount: 0)
    }

    func fetchReviewRequests(token: String) async throws -> ReviewRequests {
        if let error { throw error }
        fetchReviewRequestsTokens.append(token)
        if let reviewRequestsHandler { return try await reviewRequestsHandler(token) }
        return reviewRequests
    }

    func enqueuePullRequest(token: String, pullRequestID: String) async throws {
        if let error { throw error }
        enqueueCalls.append(pullRequestID)
        await enqueueHandler?(pullRequestID)
    }

    func markPullRequestReadyForReview(token: String, pullRequestID: String) async throws {
        if let error { throw error }
        markReadyCalls.append(pullRequestID)
    }

    func enableAutoMerge(token: String, pullRequestID: String) async throws {
        if let error { throw error }
        enableCalls.append(pullRequestID)
        await enableHandler?(pullRequestID)
    }

    func disableAutoMerge(token: String, pullRequestID: String) async throws {
        if let error { throw error }
        disableCalls.append(pullRequestID)
    }

    func mergePullRequest(token: String, repoFullName: String, number: Int) async throws -> Bool {
        if let error { throw error }
        mergePullRequestCalls.append((repoFullName, number))
        return mergeResult
    }

    func fetchPullRequestDetail(token: String, reference: PullRequestReference) async throws -> PullRequestDetailContent {
        if let error { throw error }
        detailCalls.append((token, reference))
        guard let detailHandler else { throw URLError(.fileDoesNotExist) }
        return try await detailHandler(reference)
    }

    func setFileViewed(token: String, pullRequestID: String, path: String, viewed: Bool) async throws {
        if let error { throw error }
        setFileViewedCalls.append((token, pullRequestID, path, viewed))
    }

    func fetchPullRequestComments(token: String, reference: PullRequestReference) async throws -> PullRequestComments {
        if let error { throw error }
        commentsCalls.append((token, reference))
        return comments
    }

    func postPullRequestComment(token: String, reference: PullRequestReference, comment: NewPullRequestComment) async throws {
        if let error { throw error }
        postCommentCalls.append((token, reference, comment))
    }

    func editPullRequest(token: String, reference: PullRequestReference, title: String?, body: String?) async throws {
        if let error { throw error }
        editCalls.append((token, reference, title, body))
    }
}

final class FakeTokenStore: TokenStoring {
    var token: String?
    private(set) var loadTokenCallCount = 0

    init(token: String?) {
        self.token = token
    }

    var hasToken: Bool {
        token != nil
    }

    func saveToken(_ token: String) {
        self.token = token
    }

    func loadToken() -> String? {
        loadTokenCallCount += 1
        return token
    }

    func clearToken() {
        token = nil
    }
}

final class FakeNotificationPoster: NotificationPosting {
    struct Post {
        let state: CheckState
        let title: String
        let repoFullName: String
        let number: Int
        let htmlURL: URL
    }

    private(set) var posts: [Post] = []

    func postStatusNotification(state: CheckState,
                                title: String,
                                repoFullName: String,
                                number: Int,
                                htmlURL: URL) {
        posts.append(Post(state: state,
                          title: title,
                          repoFullName: repoFullName,
                          number: number,
                          htmlURL: htmlURL))
    }
}

final class FakeDefaults: DefaultsStoring {
    var values: [String: Double] = [:]
    var stringValues: [String: String] = [:]

    func double(forKey defaultName: String) -> Double {
        values[defaultName] ?? 0
    }

    func string(forKey defaultName: String) -> String? {
        stringValues[defaultName]
    }

    func set(_ value: Double, forKey defaultName: String) {
        values[defaultName] = value
    }

    func set(_ value: String, forKey defaultName: String) {
        stringValues[defaultName] = value
    }
}

final class FakeHookRunner: PullRequestHookRunning {
    struct Run {
        let script: String
        let context: PullRequestHookContext
    }

    private(set) var runs: [Run] = []

    func run(script: String, context: PullRequestHookContext) {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        runs.append(Run(script: script, context: context))
    }
}

final class FakeDateProvider: DateProviding {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

final class PublicationCounter {
    var count = 0
}

actor SuspendedOpenRequests {
    private(set) var requestCount = 0
    private var continuations: [CheckedContinuation<OpenPullRequests, Error>] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func next() async throws -> OpenPullRequests {
        requestCount += 1
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForRequestCount(_ expected: Int) async {
        guard requestCount < expected else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resumeNext(returning response: OpenPullRequests) {
        precondition(!continuations.isEmpty)
        continuations.removeFirst().resume(returning: response)
    }
}

actor SuspendedHistoryRequests {
    private(set) var requestCount = 0
    private var continuations: [CheckedContinuation<PullRequestHistoryPage, Error>] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func next(page: Int, perPage: Int) async throws -> PullRequestHistoryPage {
        requestCount += 1
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForRequestCount(_ expected: Int) async {
        guard requestCount < expected else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resumeNext(returning response: PullRequestHistoryPage) {
        precondition(!continuations.isEmpty)
        continuations.removeFirst().resume(returning: response)
    }
}

actor MutationCalls {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record(_ id: String) {
        count += 1
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForCount(_ expected: Int) async {
        guard count < expected else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

final class FakeTimerScheduler: TimerScheduling {
    private(set) var intervals: [TimeInterval] = []
    private(set) var timers: [FakeTimer] = []

    func scheduledTimer(withTimeInterval interval: TimeInterval,
                        repeats: Bool,
                        block: @escaping @MainActor () -> Void) -> RefreshTimer {
        intervals.append(interval)
        let timer = FakeTimer()
        timers.append(timer)
        return timer
    }
}

final class FakeTimer: RefreshTimer {
    private(set) var isInvalidated = false

    func invalidate() {
        isInvalidated = true
    }
}

struct TestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func historyRow(number: Int,
                        mergedAt: Date? = Date(timeIntervalSince1970: 100)) -> PullRequestHistoryRow {
    PullRequestHistoryRow(id: "acme/widgets#\(number)",
                          title: "PR \(number)",
                          number: number,
                          repoFullName: "acme/widgets",
                          htmlURL: URL(string: "https://github.com/acme/widgets/pull/\(number)")!,
                          updatedAt: Date(timeIntervalSince1970: TimeInterval(number)),
                          closedAt: Date(timeIntervalSince1970: TimeInterval(number)),
                          mergedAt: mergedAt)
}

func row(number: Int,
                 status: CheckState,
                 autoMerge: Bool = false,
                 canEnableAutoMerge: Bool = false,
                 canDisableAutoMerge: Bool = false,
                 mergeQueue: Bool = false,
                 inMergeQueue: Bool = false,
                 isDraft: Bool = false,
                 mergeStateStatus: String = "CLEAN") -> PullRequestRow {
    PullRequestRow(id: "acme/widgets#\(number)",
                   nodeID: "node-\(number)",
                   title: "PR \(number)",
                   number: number,
                   repoFullName: "acme/widgets",
                   htmlURL: URL(string: "https://github.com/acme/widgets/pull/\(number)")!,
                   headSHA: "sha-\(number)",
                   status: status,
                   isDraft: isDraft,
                   isAutoMergeEnabled: autoMerge,
                   canEnableAutoMerge: canEnableAutoMerge,
                   canDisableAutoMerge: canDisableAutoMerge,
                   isMergeQueueEnabled: mergeQueue,
                   isInMergeQueue: inMergeQueue,
                   mergeStateStatus: mergeStateStatus,
                   updatedAt: Date(timeIntervalSince1970: TimeInterval(number)))
}

func reviewRequestRow(number: Int, author: String? = "octocat") -> ReviewRequestRow {
    ReviewRequestRow(id: "acme/widgets#\(number)",
                     title: "Review \(number)",
                     number: number,
                     repoFullName: "acme/widgets",
                     htmlURL: URL(string: "https://github.com/acme/widgets/pull/\(number)")!,
                     authorLogin: author,
                     isDraft: false,
                     updatedAt: Date(timeIntervalSince1970: TimeInterval(number)))
}
