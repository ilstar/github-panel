import XCTest
@testable import GithubPanel

final class CodeOwnersTests: XCTestCase {
    func testLastMatchAndEmptyOwnerOverride() {
        let owners = CodeOwners("* @all\n/Sources/** @acme/dev @alice\n/Sources/Generated/\n*.swift @swift # comment")
        XCTAssertEqual(owners.owners(for: "README.md"), ["@all"])
        XCTAssertEqual(owners.owners(for: "Sources/App/a.m"), ["@acme/dev", "@alice"])
        XCTAssertEqual(owners.owners(for: "Sources/Generated/a.m"), [])
        XCTAssertEqual(owners.owners(for: "Sources/App/a.swift"), ["@swift"])
    }

    func testRootedDirectoriesDoubleStarsAndCaseSensitivity() {
        let owners = CodeOwners("/docs/ @docs\n**/test?.swift @tests\napps/*/src/** @apps")
        XCTAssertEqual(owners.owners(for: "docs/nested/a.md"), ["@docs"])
        XCTAssertEqual(owners.owners(for: "other/docs/a.md"), [])
        XCTAssertEqual(owners.owners(for: "test1.swift"), ["@tests"])
        XCTAssertEqual(owners.owners(for: "nested/test2.swift"), ["@tests"])
        XCTAssertEqual(owners.owners(for: "nested/test22.swift"), [])
        XCTAssertEqual(owners.owners(for: "apps/web/src/a.swift"), ["@apps"])
        XCTAssertEqual(owners.owners(for: "apps/web/other/src/a.swift"), [])
        XCTAssertEqual(owners.owners(for: "Docs/a.md"), [])
    }

    func testSingleStarDoesNotOwnNestedFiles() {
        let owners = CodeOwners("docs/* @docs")
        XCTAssertEqual(owners.owners(for: "docs/start.md"), ["@docs"])
        XCTAssertEqual(owners.owners(for: "docs/build/troubleshooting.md"), [])
    }

    func testOwnershipIncludesUserEmailAndActiveTeams() {
        XCTAssertTrue(CodeOwners.isOwnedByViewer(["@Alice"], login: "alice", email: nil, teams: []))
        XCTAssertTrue(CodeOwners.isOwnedByViewer(["@acme/dev"], login: "alice", email: nil, teams: ["@acme/dev"]))
        XCTAssertTrue(CodeOwners.isOwnedByViewer(["a@example.com"], login: "alice", email: "a@example.com", teams: []))
        XCTAssertFalse(CodeOwners.isOwnedByViewer(["@bob", "@acme/other"], login: "alice", email: nil, teams: ["@acme/dev"]))
    }

    func testOwnershipFilterCombinesWithSearch() {
        let mine = PullRequestFile(filename: "Sources/App.swift", previousFilename: nil, status: .modified,
                                   additions: 1, deletions: 0, patch: nil, codeOwners: ["@alice"], isOwnedByViewer: true)
        let other = PullRequestFile(filename: "Sources/Other.swift", previousFilename: nil, status: .modified,
                                    additions: 1, deletions: 0, patch: nil, codeOwners: ["@bob"])
        XCTAssertEqual(FileTree.filteredFiles([mine, other], query: "sources", onlyOwnedByViewer: true), [mine])
        XCTAssertEqual(FileTree.filteredFiles([mine, other], query: "Other", onlyOwnedByViewer: true), [])
        XCTAssertEqual(FileTree.filteredFiles([mine, other], query: "", onlyOwnedByViewer: false), [mine, other])
    }
}
