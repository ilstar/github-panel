import XCTest
@testable import GithubPanel

final class CompactAgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    func testUnitsGrowWithTheAge() {
        let cases: [(seconds: TimeInterval, text: String)] = [
            (0, "now"),
            (59, "now"),
            (60, "1m"),
            (59 * 60, "59m"),
            (60 * 60, "1h"),
            (23 * 3600 + 3599, "23h"),
            (24 * 3600, "1d"),
            (6 * 86400, "6d"),
            (7 * 86400, "1w"),
            (29 * 86400, "4w"),
            (30 * 86400, "1mo"),
            (364 * 86400, "12mo"),
            (365 * 86400, "1y"),
            (800 * 86400, "2y")
        ]

        for testCase in cases {
            XCTAssertEqual(CompactAge.string(from: now.addingTimeInterval(-testCase.seconds), to: now), testCase.text,
                           "\(testCase.seconds)")
        }
    }

    func testAFutureDateReadsAsNow() {
        // The server's clock can run a little ahead of ours.
        XCTAssertEqual(CompactAge.string(from: now.addingTimeInterval(90), to: now), "now")
    }
}
