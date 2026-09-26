import XCTest
@testable import GithubPanel

final class DiffGutterTextTests: XCTestCase {
    func testUnifiedPrefixRightAlignsBothNumbersBeforeTheMarker() {
        XCTAssertEqual(DiffGutterText.prefix(numbers: [12, 130], kind: .context), "    12    130    ")
        XCTAssertEqual(DiffGutterText.prefix(numbers: [nil, 7], kind: .addition), "            7  + ")
        XCTAssertEqual(DiffGutterText.prefix(numbers: [4, nil], kind: .deletion), "     4         - ")
    }

    func testEveryPrefixHasTheSameWidthSoTheTextLinesUp() {
        let widths = Set([
            DiffGutterText.prefix(numbers: [1, 1], kind: .context),
            DiffGutterText.prefix(numbers: [999_999, nil], kind: .deletion),
            DiffGutterText.prefix(numbers: [nil, nil], kind: .hunk)
        ].map(\.count))

        XCTAssertEqual(widths, [2 * DiffGutterText.columnWidth + DiffGutterText.markerWidth])
    }

    func testSplitPrefixHasOneColumn() {
        XCTAssertEqual(DiffGutterText.prefix(numbers: [42], kind: .addition), "    42  + ")
    }
}
