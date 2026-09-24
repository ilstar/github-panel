import XCTest
@testable import GithubPanel

@MainActor
final class MockGitHubAPITests: XCTestCase {
    func testEmptyMockGitHubAPIHasNoPullRequests() async throws {
        let api = MockGitHubAPI(isEmpty: true)

        let result = try await api.fetchOpenPRs(token: "token")

        XCTAssertTrue(result.rows.isEmpty)
    }
}
