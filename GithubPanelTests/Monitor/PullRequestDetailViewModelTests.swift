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

    private func detailContent(title: String, files: [PullRequestFile] = []) -> PullRequestDetailContent {
        PullRequestDetailContent(
            detail: PullRequestDetail(reference: reference,
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
