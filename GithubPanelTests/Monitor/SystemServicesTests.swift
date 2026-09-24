import XCTest
@testable import GithubPanel

@MainActor
final class SystemServicesTests: XCTestCase {
    func testSystemTimerSchedulerSetsTolerance() throws {
        let refreshTimer = SystemTimerScheduler().scheduledTimer(withTimeInterval: 60, repeats: true) {}
        let timer = try XCTUnwrap(refreshTimer as? Timer)
        defer { timer.invalidate() }

        XCTAssertEqual(timer.tolerance, 6, accuracy: 0.001)
    }
}
