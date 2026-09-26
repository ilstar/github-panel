import XCTest
@testable import GithubPanel

@MainActor
final class MockGitHubAPITests: XCTestCase {
    func testEmptyMockGitHubAPIHasNoPullRequests() async throws {
        let api = MockGitHubAPI(isEmpty: true)

        let result = try await api.fetchOpenPRs(token: "token")

        XCTAssertTrue(result.rows.isEmpty)
    }

    func testMockDetailUsesTheListTitleAndParsableDiffs() async throws {
        let api = MockGitHubAPI()
        let reference = PullRequestReference(repoFullName: "mock/github-panel", number: 109)

        let content = try await api.fetchPullRequestDetail(token: "token", reference: reference)

        XCTAssertEqual(content.detail.title, "Draft: success but not mergeable")
        XCTAssertEqual(content.detail.state, .draft)
        XCTAssertEqual(content.detail.changedFiles, content.files.count)
        XCTAssertTrue(content.files.contains { $0.patch == nil })
        for file in content.files {
            guard let patch = file.patch else { continue }
            let lines = DiffParser.parse(patch)
            XCTAssertEqual(lines.filter { $0.kind == .addition }.count, file.additions, file.filename)
            XCTAssertEqual(lines.filter { $0.kind == .deletion }.count, file.deletions, file.filename)
        }
    }
}
