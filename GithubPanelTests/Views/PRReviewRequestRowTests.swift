import XCTest
@testable import GithubPanel

final class PRReviewRequestRowTests: XCTestCase {
    func testSubtitleShowsTheSizeWhenGitHubReportsIt() {
        var pr = reviewRequestRow(number: 4)
        XCTAssertEqual(PRReviewRequestRow.subtitleText(for: pr), "acme/widgets#4")

        pr.additions = 120
        pr.deletions = 30
        XCTAssertEqual(PRReviewRequestRow.subtitleText(for: pr), "acme/widgets#4 · +120 −30")
    }
}
