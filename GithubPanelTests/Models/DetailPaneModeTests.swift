import XCTest
@testable import GithubPanel

final class DetailPaneModeTests: XCTestCase {
    func testSettingsOffersNativeThenGitHub() {
        XCTAssertEqual(DetailPaneMode.allCases.map(\.title), ["Native", "GitHub.com"])
    }

    func testDefaultsToNativeWhenNothingIsSaved() {
        XCTAssertEqual(DetailPaneMode.stored(in: FakeDefaults()), .native)
    }

    func testReadsTheSavedChoice() {
        let defaults = FakeDefaults()
        defaults.set("web", forKey: DetailPaneMode.defaultsKey)
        XCTAssertEqual(DetailPaneMode.stored(in: defaults), .web)
    }

    func testFallsBackToNativeForAnUnknownValue() {
        let defaults = FakeDefaults()
        defaults.set("iframe", forKey: DetailPaneMode.defaultsKey)
        XCTAssertEqual(DetailPaneMode.stored(in: defaults), .native)
    }

    func testReferenceWebURLIsThePullRequestPage() {
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 12)
        XCTAssertEqual(reference.webURL, URL(string: "https://github.com/acme/widgets/pull/12"))
    }
}
