import XCTest
@testable import GithubPanel

final class BranchLinkTests: XCTestCase {
    func testBranchSurvivesTheRoundTripThroughItsLink() throws {
        for branch in ["main", "fred/fix-thing", "feature/a+b&c=d #1", "ünïcode"] {
            let url = try XCTUnwrap(BranchLink.url(for: branch))
            XCTAssertEqual(BranchLink.branch(from: url), branch)
        }
    }

    func testOtherLinksAreNotBranches() throws {
        XCTAssertNil(BranchLink.branch(from: try XCTUnwrap(URL(string: "https://github.com/o/r?name=main"))))
    }

    func testSummaryLinksBothBranches() throws {
        let detail = PullRequestDetail(reference: PullRequestReference(repoFullName: "acme/widgets", number: 7),
                                       nodeID: "PR_node",
                                       title: "Title",
                                       body: "",
                                       authorLogin: "octocat",
                                       state: .open,
                                       baseRef: "main",
                                       headRef: "fred/feature",
                                       headSHA: "abc123",
                                       htmlURL: try XCTUnwrap(URL(string: "https://github.com/acme/widgets/pull/7")),
                                       createdAt: Date(timeIntervalSince1970: 0),
                                       additions: 0,
                                       deletions: 0,
                                       changedFiles: 0,
                                       commits: 2,
                                       canEdit: false)
        let summary = PullRequestDetailHeader.summary(for: detail)

        let links = summary.runs.compactMap { run in run.link.flatMap(BranchLink.branch(from:)) }
        XCTAssertEqual(links, [detail.baseRef, detail.headRef])
        XCTAssertTrue(String(summary.characters).contains("wants to merge"))
    }
}
