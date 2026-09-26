import XCTest
@testable import GithubPanel

@MainActor
final class PullRequestDetailViewModelTests: XCTestCase {
    private let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)

    func testLoadStoresContent() async {
        let content = detailContent(title: "First")
        var fetched: [PullRequestReference] = []
        let viewModel = PullRequestDetailViewModel(reference: reference) { reference in
            fetched.append(reference)
            return content
        }

        await viewModel.load()

        XCTAssertEqual(fetched, [reference])
        XCTAssertEqual(viewModel.content, content)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadParsesEachFilePatch() async {
        let files = [
            PullRequestFile(filename: "a.swift", previousFilename: nil, status: .modified,
                            additions: 1, deletions: 1, patch: "@@ -1 +1 @@\n-a\n+b"),
            PullRequestFile(filename: "logo.png", previousFilename: nil, status: .added,
                            additions: 0, deletions: 0, patch: nil)
        ]
        let content = detailContent(title: "Files", files: files)
        let viewModel = PullRequestDetailViewModel(reference: reference) { _ in content }

        await viewModel.load()

        XCTAssertEqual(viewModel.diffLines["a.swift"]?.map(\.kind), [.hunk, .deletion, .addition])
        XCTAssertEqual(viewModel.diffLines["logo.png"], [])
    }

    func testLoadReadsViewedFiles() async {
        let files = [
            file("a.swift", isViewed: true),
            file("b.swift", isViewed: false)
        ]
        let viewModel = PullRequestDetailViewModel(reference: reference) { [self] _ in
            detailContent(title: "Viewed", files: files)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.viewedFiles, ["a.swift"])
    }

    func testSetViewedUpdatesRightAwayAndSyncs() async {
        var calls: [(String, String, Bool)] = []
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Viewed", files: [file("a.swift")]) },
                                                   setViewed: { id, path, viewed in calls.append((id, path, viewed)) })
        await viewModel.load()

        await viewModel.setViewed(true, filename: "a.swift")
        XCTAssertEqual(viewModel.viewedFiles, ["a.swift"])

        await viewModel.setViewed(true, filename: "a.swift")
        await viewModel.setViewed(false, filename: "a.swift")

        XCTAssertEqual(viewModel.viewedFiles, [])
        XCTAssertEqual(calls.map(\.0), ["PR_node", "PR_node"])
        XCTAssertEqual(calls.map(\.1), ["a.swift", "a.swift"])
        XCTAssertEqual(calls.map(\.2), [true, false])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testFailedSetViewedRestoresMarkAndShowsError() async {
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Viewed", files: [file("a.swift")]) },
                                                   setViewed: { _, _, _ in
                                                       throw GraphQLError(message: "Resource not accessible")
                                                   })
        await viewModel.load()

        await viewModel.setViewed(true, filename: "a.swift")

        XCTAssertEqual(viewModel.viewedFiles, [])
        XCTAssertEqual(viewModel.errorMessage, "Resource not accessible")
    }

    func testSetViewedBeforeLoadDoesNothing() async {
        var calls = 0
        let viewModel = PullRequestDetailViewModel(reference: reference,
                                                   fetch: { [self] _ in detailContent(title: "Viewed") },
                                                   setViewed: { _, _, _ in calls += 1 })

        await viewModel.setViewed(true, filename: "a.swift")

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(viewModel.viewedFiles, [])
    }

    func testPresentationHonorsHiddenWhitespace() async {
        let patch = "@@ -1,2 +1,2 @@\n-  a\n-b\n+    a\n+c"
        let viewModel = PullRequestDetailViewModel(reference: reference) { [self] _ in
            detailContent(title: "Diff", files: [file("a.swift", patch: patch)])
        }
        await viewModel.load()

        let shown = viewModel.presentation(for: "a.swift", hideWhitespace: false)
        let hidden = viewModel.presentation(for: "a.swift", hideWhitespace: true)

        XCTAssertEqual(shown.unified.map(\.kind), [.hunk, .deletion, .deletion, .addition, .addition])
        XCTAssertEqual(hidden.unified.map(\.kind), [.hunk, .context, .deletion, .addition])
        XCTAssertEqual(viewModel.presentation(for: "missing.swift", hideWhitespace: false).unified, [])
    }

    func testFailedReloadKeepsPreviousContentAndShowsError() async {
        let content = detailContent(title: "First")
        var shouldFail = false
        let viewModel = PullRequestDetailViewModel(reference: reference) { _ in
            if shouldFail { throw GitHubAPIError(message: "Not Found", documentationURL: nil, statusCode: 404) }
            return content
        }
        await viewModel.load()

        shouldFail = true
        await viewModel.load()

        XCTAssertEqual(viewModel.content, content)
        XCTAssertEqual(viewModel.errorMessage, "GitHub API error (404): Not Found")

        shouldFail = false
        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
    }

    func testMonitorFetchesDetailWithSessionToken() async throws {
        let api = FakeGitHubAPI()
        let content = detailContent(title: "From API")
        api.detailHandler = { _ in content }
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        let result = try await monitor.fetchPullRequestDetail(reference)

        XCTAssertEqual(result, content)
        XCTAssertEqual(api.detailCalls.map(\.token), ["token"])
        XCTAssertEqual(api.detailCalls.map(\.reference), [reference])
    }

    func testMonitorSetsFileViewedWithSessionToken() async throws {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"))

        try await monitor.setFileViewed(pullRequestID: "PR_node", path: "a.swift", viewed: true)

        XCTAssertEqual(api.setFileViewedCalls.map(\.token), ["token"])
        XCTAssertEqual(api.setFileViewedCalls.map(\.pullRequestID), ["PR_node"])
        XCTAssertEqual(api.setFileViewedCalls.map(\.path), ["a.swift"])
        XCTAssertEqual(api.setFileViewedCalls.map(\.viewed), [true])
    }

    func testMonitorFetchWithoutTokenFails() async {
        let api = FakeGitHubAPI()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: nil))

        do {
            _ = try await monitor.fetchPullRequestDetail(reference)
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is MissingTokenError)
        }
        XCTAssertTrue(api.detailCalls.isEmpty)
    }

    private func file(_ filename: String, patch: String? = nil, isViewed: Bool = false) -> PullRequestFile {
        PullRequestFile(filename: filename, previousFilename: nil, status: .modified,
                        additions: 1, deletions: 1, patch: patch, isViewed: isViewed)
    }

    private func detailContent(title: String, files: [PullRequestFile] = []) -> PullRequestDetailContent {
        PullRequestDetailContent(
            detail: PullRequestDetail(reference: reference,
                                      nodeID: "PR_node",
                                      title: title,
                                      body: "",
                                      authorLogin: "octocat",
                                      state: .open,
                                      baseRef: "main",
                                      headRef: "feature",
                                      htmlURL: URL(string: "https://github.com/acme/widgets/pull/7")!,
                                      createdAt: Date(timeIntervalSince1970: 0),
                                      additions: 0,
                                      deletions: 0,
                                      changedFiles: 0,
                                      commits: 1),
            files: files
        )
    }
}
