import XCTest
@testable import GithubPanel

final class PullRequestDetailHeaderTests: XCTestCase {
    func testEditTitleButtonSitsByTheTitleOfYourOwnPullRequest() async throws {
        let detail = try await mockDetail(own: true)
        XCTAssertTrue(detail.canEdit)
        XCTAssertTrue(PullRequestDetailHeader.showsEditTitleButton(for: detail))
    }

    func testNoEditTitleButtonWhenYouCannotEditThePullRequest() async throws {
        let detail = try await mockDetail(own: false)
        XCTAssertFalse(detail.canEdit)
        XCTAssertFalse(PullRequestDetailHeader.showsEditTitleButton(for: detail))
    }

    private func mockDetail(own: Bool) async throws -> PullRequestDetail {
        let api = MockGitHubAPI()
        let reference: PullRequestReference
        if own {
            reference = PullRequestReference(repoFullName: "mock/github-panel", number: 109)
        } else {
            let requests = try await api.fetchReviewRequests(token: "token")
            let row = try XCTUnwrap(requests.rows.first)
            reference = PullRequestReference(repoFullName: row.repoFullName, number: row.number)
        }
        return try await api.fetchPullRequestDetail(token: "token", reference: reference).detail
    }
}
