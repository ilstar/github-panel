import XCTest
@testable import GithubPanel

final class CheckStateTests: XCTestCase {
    func testGitHubStatusMapping() {
        XCTAssertEqual(CheckState(githubStatus: "SUCCESS"), .success)
        XCTAssertEqual(CheckState(githubStatus: nil), .success)
        XCTAssertEqual(CheckState(githubStatus: "FAILURE"), .failure)
        XCTAssertEqual(CheckState(githubStatus: "ERROR"), .error)
        XCTAssertEqual(CheckState(githubStatus: "PENDING"), .pending)
        XCTAssertEqual(CheckState(githubStatus: "EXPECTED"), .pending)
        XCTAssertEqual(CheckState(githubStatus: "QUEUED"), .unknown)
    }

    func testEmojiAndDescriptions() {
        XCTAssertEqual(CheckState.success.emoji, "✅")
        XCTAssertEqual(CheckState.failure.emoji, "❌")
        XCTAssertEqual(CheckState.error.emoji, "❌")
        XCTAssertEqual(CheckState.pending.emoji, "⏳")
        XCTAssertEqual(CheckState.unknown.emoji, "❔")

        XCTAssertEqual(CheckState.success.descriptionText, "All checks are done.")
        XCTAssertEqual(CheckState.failure.descriptionText, "Checks failed.")
        XCTAssertEqual(CheckState.error.descriptionText, "Checks failed.")
        XCTAssertEqual(CheckState.pending.descriptionText, "Still building.")
        XCTAssertEqual(CheckState.unknown.descriptionText, "Status unavailable.")
    }
}
