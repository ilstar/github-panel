import XCTest
@testable import GithubPanel

final class ContentViewTests: XCTestCase {
    func testRefreshTimelineOnlyUpdatesWhileAnimating() {
        XCTAssertFalse(RefreshAnimation.shouldUpdateTimeline(isLoading: false, isSettling: false))
        XCTAssertTrue(RefreshAnimation.shouldUpdateTimeline(isLoading: true, isSettling: false))
        XCTAssertTrue(RefreshAnimation.shouldUpdateTimeline(isLoading: false, isSettling: true))
    }

    func testRefreshAnimationCompletesItsCurrentCycle() {
        let firstCycle = RefreshAnimation.stopPlan(elapsed: 0.4)
        XCTAssertEqual(firstCycle.cycle, 1)
        XCTAssertEqual(firstCycle.delay, 1.2, accuracy: 0.000_001)

        let aligned = RefreshAnimation.stopPlan(elapsed: 1.6)
        XCTAssertEqual(aligned.cycle, 1)
        XCTAssertEqual(aligned.delay, 0, accuracy: 0.000_001)

        let secondCycle = RefreshAnimation.stopPlan(elapsed: 1.7)
        XCTAssertEqual(secondCycle.cycle, 2)
        XCTAssertEqual(secondCycle.delay, 1.5, accuracy: 0.000_001)
    }
}
