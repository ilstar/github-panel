import XCTest
@testable import GithubPanel

final class RefreshPillTests: XCTestCase {
    func testARefreshWidensThePillBeforeTheIconSpins() {
        let phase = RefreshPillPhase.idle.refreshStarted()
        XCTAssertEqual(phase, .expanding)
        XCTAssertTrue(phase.isExpanded)
        XCTAssertFalse(phase.isSpinning)

        XCTAssertEqual(phase.expanded(isRefreshing: true), .spinning)
        XCTAssertTrue(RefreshPillPhase.spinning.isSpinning)
    }

    func testTheIconFinishesItsTurnBeforeThePillNarrows() {
        let stopping = RefreshPillPhase.spinning.refreshEnded()
        XCTAssertEqual(stopping, .stopping)
        XCTAssertTrue(stopping.isSpinning)
        XCTAssertTrue(stopping.isExpanded)
        XCTAssertFalse(RefreshPillPhase.idle.isExpanded)
        XCTAssertFalse(RefreshPillPhase.idle.isSpinning)
    }

    func testARefreshThatEndsWhileWideningNarrowsWithoutSpinning() {
        XCTAssertEqual(RefreshPillPhase.expanding.refreshEnded(), .expanding)
        XCTAssertEqual(RefreshPillPhase.expanding.expanded(isRefreshing: false), .idle)
    }

    func testARefreshStartingWhileTheIconStopsKeepsItSpinning() {
        XCTAssertEqual(RefreshPillPhase.stopping.refreshStarted(), .spinning)
        XCTAssertEqual(RefreshPillPhase.spinning.refreshStarted(), .spinning)
        XCTAssertEqual(RefreshPillPhase.expanding.refreshStarted(), .expanding)
    }

    func testOnlyAWideningPillMovesOnWhenItIsWide() {
        XCTAssertEqual(RefreshPillPhase.idle.expanded(isRefreshing: true), .idle)
        XCTAssertEqual(RefreshPillPhase.stopping.expanded(isRefreshing: false), .stopping)
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
