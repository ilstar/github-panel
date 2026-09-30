import AppKit
import SwiftUI
import XCTest
@testable import GithubPanel

final class PullRequestTextSizeTests: XCTestCase {
    func testDefaultPreservesExistingSizesAndChangesScaleTogether() {
        for base: CGFloat in [12, 13, 17, 26] {
            XCTAssertEqual(PullRequestTextSize.scaled(base, setting: 13), base)
            XCTAssertEqual(PullRequestTextSize.scaled(base, setting: 16), base + 3)
            XCTAssertEqual(PullRequestTextSize.scaled(base, setting: 11), base - 2)
        }
    }

    func testOutOfRangePreferencesAreClamped() {
        XCTAssertEqual(PullRequestTextSize.clamped(-100), 11)
        XCTAssertEqual(PullRequestTextSize.clamped(100), 20)
        XCTAssertEqual(PullRequestTextSize.clamped(15), 15)
        var environment = EnvironmentValues()
        environment.pullRequestTextSize = 100
        XCTAssertEqual(environment.pullRequestTextSize, 20)
    }

    func testLargerCodeFontAlsoIncreasesGutterCharacterWidth() {
        let small = PullRequestTextSize.codeFont(setting: 11)
        let large = PullRequestTextSize.codeFont(setting: 20)
        XCTAssertEqual(small.pointSize, 10)
        XCTAssertEqual(large.pointSize, 19)
        let width = { (font: NSFont) in ("0" as NSString).size(withAttributes: [.font: font]).width }
        XCTAssertGreaterThan(width(large), width(small))
        XCTAssertEqual(PullRequestTextSize.codeCharacterWidth(setting: 20), width(large))
    }

    @MainActor
    func testMarkdownRespondsToTextSizeIncludingHeadingsCodeAndTables() {
        let markdown = "## Heading\n\nReadable paragraph\n\n```swift\nlet value = 1\n```\n\n| Name |\n| --- |\n| Value |"
        func height(size: Int) -> CGFloat {
            let host = NSHostingView(rootView: MarkdownView(markdown: markdown)
                .environment(\.pullRequestTextSize, size)
                .frame(width: 500))
            return host.fittingSize.height
        }
        XCTAssertGreaterThan(height(size: 20), height(size: 11))
    }
}
