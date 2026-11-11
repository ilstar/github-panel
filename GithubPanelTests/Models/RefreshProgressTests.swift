import XCTest
@testable import GithubPanel

final class RefreshProgressTests: XCTestCase {
    func testCountsTheLoadingPullRequestOfTheSelectedTabsList() {
        var progress = RefreshProgress()
        progress.add(reference(1), to: .myPullRequests)
        progress.add(reference(2), to: .myPullRequests)
        progress.add(reference(8), to: .reviewRequests)

        XCTAssertEqual(progress.text(selectedTab: .open), "Refreshing My PRs 1/2…")
        XCTAssertEqual(progress.text(selectedTab: .reviews), "Refreshing To Review 1/1…")

        progress.complete(reference(1))
        XCTAssertEqual(progress.text(selectedTab: .open), "Refreshing My PRs 2/2…")
    }

    func testShowsTheOtherListOnceTheSelectedOneIsDoneAndNothingWhenBothAre() {
        var progress = RefreshProgress()
        progress.add(reference(1), to: .myPullRequests)
        progress.add(reference(8), to: .reviewRequests)
        progress.complete(reference(8))

        XCTAssertEqual(progress.text(selectedTab: .reviews), "Refreshing My PRs 1/1…")

        progress.complete(reference(1))
        XCTAssertNil(progress.text(selectedTab: .reviews))
        XCTAssertNil(progress.text(selectedTab: .open))
    }

    func testAPullRequestInBothListsCountsOnceInTheFirst() {
        var progress = RefreshProgress()
        progress.add(reference(1), to: .myPullRequests)
        progress.add(reference(1), to: .reviewRequests)

        XCTAssertEqual(progress.count(of: .myPullRequests), RefreshProgress.Count(completed: 0, total: 1))
        XCTAssertEqual(progress.count(of: .reviewRequests), RefreshProgress.Count(completed: 0, total: 0))
    }

    func testAPullRequestQueuedAgainCountsAsNotDone() {
        var progress = RefreshProgress()
        progress.add(reference(1), to: .myPullRequests)
        progress.complete(reference(1))
        progress.add(reference(1), to: .myPullRequests)

        XCTAssertEqual(progress.count(of: .myPullRequests), RefreshProgress.Count(completed: 0, total: 1))
    }

    func testCompletingAnUnqueuedPullRequestCountsNothing() {
        var progress = RefreshProgress()
        progress.complete(reference(1))

        XCTAssertEqual(progress.count(of: .myPullRequests), RefreshProgress.Count(completed: 0, total: 0))
    }

    private func reference(_ number: Int) -> PullRequestReference {
        PullRequestReference(repoFullName: "acme/widgets", number: number)
    }
}
