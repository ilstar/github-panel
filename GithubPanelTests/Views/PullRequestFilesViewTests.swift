import XCTest
@testable import GithubPanel

final class PullRequestFilesViewTests: XCTestCase {
    func testDisplayNameShowsRenames() {
        XCTAssertEqual(PullRequestFileHeader.displayName(file(filename: "New.swift", previousFilename: "Old.swift")),
                       "Old.swift → New.swift")
        XCTAssertEqual(PullRequestFileHeader.displayName(file(filename: "Same.swift", previousFilename: nil)),
                       "Same.swift")
    }

    func testStatusLabels() {
        XCTAssertEqual(PullRequestFileHeader.statusLabel(.removed), "DELETED")
        XCTAssertEqual(PullRequestFileHeader.statusLabel(.changed), "MODIFIED")
    }

    private func file(filename: String, previousFilename: String?) -> PullRequestFile {
        PullRequestFile(filename: filename,
                        previousFilename: previousFilename,
                        status: previousFilename == nil ? .modified : .renamed,
                        additions: 0,
                        deletions: 0,
                        patch: nil)
    }
}
