import XCTest
@testable import GithubPanel

final class MergeMethodTests: XCTestCase {
    func testDefaultMethodIsTheSuggestedOneWhenAllowed() {
        let methods = RepositoryMergeMethods(allowed: [.merge, .squash], suggested: .squash)

        XCTAssertEqual(methods.defaultMethod, .squash)
    }

    func testDefaultMethodFallsBackToTheFirstAllowedOne() {
        let methods = RepositoryMergeMethods(allowed: [.squash, .rebase], suggested: .merge)

        XCTAssertEqual(methods.defaultMethod, .squash)
    }

    func testNoAllowedMethodsMeansMergeCommits() {
        XCTAssertEqual(RepositoryMergeMethods(allowed: [], suggested: .squash).allowed, [.merge])
    }

    func testMergeButtonNamesTheMethod() {
        XCTAssertEqual(MergeButtonState.merge.title(mergeMethod: .merge), "Merge")
        XCTAssertEqual(MergeButtonState.merge.title(mergeMethod: .squash), "Squash and merge")
        XCTAssertEqual(MergeButtonState.merge.title(mergeMethod: .rebase), "Rebase and merge")
        XCTAssertEqual(MergeButtonState.enableAutoMerge.title(mergeMethod: .squash), "Enable auto-merge")
    }
}
