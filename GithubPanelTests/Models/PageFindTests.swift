import XCTest
import WebKit
@testable import GithubPanel

@MainActor
final class PageFindTests: XCTestCase {
    func testTypingSearchesFromTheCurrentMatch() async throws {
        let finder = FakeFinder(matches: ["review"])
        let find = PageFind()
        find.finder = finder

        find.query = "rev"
        try await waitUntil { find.result == .found }
        find.query = "review"
        try await waitUntil { finder.searches.count == 2 && find.result == .found }

        XCTAssertEqual(finder.searches, [.init(text: "rev", backwards: false, fromSelectionStart: true),
                                         .init(text: "review", backwards: false, fromSelectionStart: true)])
    }

    func testNoMatchSaysNotFound() async throws {
        let finder = FakeFinder(matches: [])
        let find = PageFind()
        find.finder = finder

        find.query = "missing"

        try await waitUntil { find.result == .notFound }
        withExtendedLifetime(finder) {}
    }

    func testNextAndPreviousMoveFromTheMatch() async throws {
        let finder = FakeFinder(matches: ["fix"])
        let find = PageFind()
        find.finder = finder
        find.query = "fix"

        find.findNext()
        find.findPrevious()
        try await waitUntil { finder.searches.count == 3 }

        XCTAssertEqual(Array(finder.searches.dropFirst()),
                       [.init(text: "fix", backwards: false, fromSelectionStart: false),
                        .init(text: "fix", backwards: true, fromSelectionStart: false)])
    }

    func testFindNextWithNothingTypedOpensTheBar() {
        let finder = FakeFinder(matches: [])
        let find = PageFind()
        find.finder = finder

        find.findNext()

        XCTAssertTrue(find.isVisible)
        XCTAssertEqual(find.focusRequest, 1)
        XCTAssertTrue(finder.searches.isEmpty)
    }

    func testShowingAgainRefocusesTheField() {
        let find = PageFind()

        find.show()
        find.show()

        XCTAssertTrue(find.isVisible)
        XCTAssertEqual(find.focusRequest, 2)
    }

    func testClearingTheQueryClearsTheResult() async throws {
        let finder = FakeFinder(matches: [])
        let find = PageFind()
        find.finder = finder
        find.query = "missing"
        try await waitUntil { find.result == .notFound }

        find.query = ""

        XCTAssertEqual(find.result, .none)
        withExtendedLifetime(finder) {}
    }

    func testHidingHandsTheKeyboardBackToThePage() {
        let finder = FakeFinder(matches: [])
        let find = PageFind()
        find.finder = finder
        find.show()

        find.hide()

        XCTAssertFalse(find.isVisible)
        XCTAssertEqual(finder.focusCount, 1)
    }

    func testAnotherPageStartsWithNoResult() async throws {
        let finder = FakeFinder(matches: [])
        let find = PageFind()
        find.finder = finder
        find.query = "missing"
        try await waitUntil { find.result == .notFound }

        let other = FakeFinder(matches: [])
        find.finder = other

        XCTAssertEqual(find.result, .none)
        withExtendedLifetime(finder) {}
    }

    func testFindsTextInARealWebView() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        webView.loadHTMLString("<p>Looks good to me</p><p>Please fix the typo</p>", baseURL: nil)
        try await waitUntil { !webView.isLoading && webView.url != nil }

        let found = await webView.findText("TYPO", backwards: false, fromSelectionStart: true)
        let missing = await webView.findText("unicorn", backwards: false, fromSelectionStart: true)

        XCTAssertTrue(found)
        XCTAssertFalse(missing)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
private final class FakeFinder: PageTextFinder {
    struct Search: Equatable {
        let text: String
        let backwards: Bool
        let fromSelectionStart: Bool
    }

    let matches: [String]
    private(set) var searches: [Search] = []
    private(set) var focusCount = 0

    init(matches: [String]) {
        self.matches = matches
    }

    func findText(_ text: String, backwards: Bool, fromSelectionStart: Bool) async -> Bool {
        searches.append(Search(text: text, backwards: backwards, fromSelectionStart: fromSelectionStart))
        return matches.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    func focusPage() {
        focusCount += 1
    }
}
