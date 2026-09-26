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
        XCTAssertEqual(CheckState(githubStatus: "EXPECTED", hasCheckContexts: false), .noChecks)
        XCTAssertEqual(CheckState(githubStatus: "EXPECTED", hasCheckContexts: true), .pending)
        XCTAssertEqual(CheckState(githubStatus: "QUEUED"), .unknown)
    }

    func testEmojiAndDescriptions() {
        XCTAssertEqual(CheckState.success.emoji, "✅")
        XCTAssertEqual(CheckState.failure.emoji, "❌")
        XCTAssertEqual(CheckState.error.emoji, "❌")
        XCTAssertEqual(CheckState.pending.emoji, "⏳")
        XCTAssertEqual(CheckState.unknown.emoji, "❔")

        XCTAssertEqual(CheckState.success.descriptionText, "All checks passed.")
        XCTAssertEqual(CheckState.noChecks.descriptionText, "No checks configured.")
        XCTAssertEqual(CheckState.failure.descriptionText, "Some checks failed.")
        XCTAssertEqual(CheckState.error.descriptionText, "Some checks failed.")
        XCTAssertEqual(CheckState.pending.descriptionText, "Checks in progress.")
        XCTAssertEqual(CheckState.unknown.descriptionText, "Status unavailable.")
    }
}
