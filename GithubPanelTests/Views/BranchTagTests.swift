import XCTest
@testable import GithubPanel

final class BranchTagTests: XCTestCase {
    func testSummaryLeadCountsCommits() {
        XCTAssertEqual(PullRequestDetailHeader.summaryLead(for: detail(commits: 1)), "octocat wants to merge 1 commit into")
        XCTAssertEqual(PullRequestDetailHeader.summaryLead(for: detail(commits: 3)), "octocat wants to merge 3 commits into")
    }

    private func detail(commits: Int) -> PullRequestDetail {
        PullRequestDetail(reference: PullRequestReference(repoFullName: "acme/widgets", number: 7),
                          nodeID: "PR_node",
                          title: "Title",
                          body: "",
                          authorLogin: "octocat",
                          state: .open,
                          baseRef: "main",
                          headRef: "fred/feature",
                          headSHA: "abc123",
                          htmlURL: URL(string: "https://github.com/acme/widgets/pull/7")!,
                          createdAt: Date(timeIntervalSince1970: 0),
                          additions: 0,
                          deletions: 0,
                          changedFiles: 0,
                          commits: commits,
                          canEdit: false)
    }
}
