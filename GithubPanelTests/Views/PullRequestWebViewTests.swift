import XCTest
import WebKit
@testable import GithubPanel

final class PullRequestWebViewTests: XCTestCase {
    func testGitHubPagesStayInThePane() {
        for link in ["https://github.com/acme/widgets/pull/12/files",
                     "https://gist.github.com/someone/abc",
                     "https://GitHub.com/login"] {
            XCTAssertEqual(WebNavigationPolicy.decision(for: URL(string: link), isLinkClick: true), .allow, link)
        }
    }

    func testClickedLinksToOtherSitesOpenInTheBrowser() {
        XCTAssertEqual(WebNavigationPolicy.decision(for: URL(string: "https://buildkite.com/acme/builds/1"),
                                                    isLinkClick: true), .openExternally)
        XCTAssertEqual(WebNavigationPolicy.decision(for: URL(string: "https://notgithub.com/"),
                                                    isLinkClick: true), .openExternally)
    }

    func testRedirectsToOtherSitesLoadInThePaneSoSSOSignInWorks() {
        XCTAssertEqual(WebNavigationPolicy.decision(for: URL(string: "https://acme.okta.com/sso/saml"),
                                                    isLinkClick: false), .allow)
    }

    func testOtherSchemesOpenOutsideExceptPageInternals() {
        XCTAssertEqual(WebNavigationPolicy.decision(for: URL(string: "mailto:someone@example.com"),
                                                    isLinkClick: true), .openExternally)
        XCTAssertEqual(WebNavigationPolicy.decision(for: URL(string: "about:blank"), isLinkClick: false), .allow)
        XCTAssertEqual(WebNavigationPolicy.decision(for: URL(string: "webkit-extension://abc/options.html"),
                                                    isLinkClick: true), .allow)
        XCTAssertEqual(WebNavigationPolicy.decision(for: nil, isLinkClick: false), .allow)
    }

    func testPathLabelDropsTheGitHubHost() {
        XCTAssertEqual(PullRequestWebPane.pathLabel(for: URL(string: "https://github.com/acme/widgets/pull/12/files")),
                       "acme/widgets/pull/12/files")
        XCTAssertEqual(PullRequestWebPane.pathLabel(for: URL(string: "https://github.com/")), "github.com")
        XCTAssertEqual(PullRequestWebPane.pathLabel(for: URL(string: "https://acme.okta.com/sso")), "acme.okta.com/sso")
        XCTAssertNil(PullRequestWebPane.pathLabel(for: nil))
    }

    @MainActor
    func testFocusInAWebViewCountsAsTypingSoPageKeysReachTheWeb() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(webView)

        XCTAssertFalse(KeyCommand.isTyping(in: window))

        window.makeFirstResponder(webView)
        XCTAssertTrue(KeyCommand.isTyping(in: window))

        window.endTyping()
        XCTAssertFalse(KeyCommand.isTyping(in: window))
    }

    @MainActor
    func testPoolLoadsAFewPagesAtATimeInPlanOrder() {
        let pool = PullRequestWebPool()
        let plan = candidates(1...3)

        pool.keep(plan)

        XCTAssertEqual(Set(pool.pages.keys), Set(plan.map(\.reference)))
        XCTAssertEqual(pool.loadingCount, PullRequestWebPool.maxConcurrentLoads)
        let first = pool.pages[plan[0].reference]!
        XCTAssertNil(first.conversation.pendingURL)
        XCTAssertNil(first.files.pendingURL)
        XCTAssertNotNil(pool.pages[plan[2].reference]!.conversation.pendingURL)
        pool.removeAll()
    }

    @MainActor
    func testShowingAPullRequestLoadsItsPageAheadOfTheQueue() {
        let pool = PullRequestWebPool()
        let plan = candidates(1...3)
        pool.keep(plan)

        pool.show(plan[2].reference)

        XCTAssertEqual(pool.shown, plan[2].reference)
        XCTAssertNil(pool.pages[plan[2].reference]!.conversation.pendingURL)
        pool.removeAll()
    }

    @MainActor
    func testPoolDropsPullRequestsOutOfThePlanButKeepsTheShownOne() {
        let pool = PullRequestWebPool()
        let plan = candidates(1...3)
        pool.keep(plan)
        pool.show(plan[2].reference)

        pool.keep([plan[0]])

        XCTAssertEqual(Set(pool.pages.keys), [plan[0].reference, plan[2].reference])
        XCTAssertLessThanOrEqual(pool.loadingCount, 2 * pool.pages.count)
        pool.removeAll()
    }

    @MainActor
    func testAnEmptyPlanDropsEverything() {
        let pool = PullRequestWebPool()
        pool.keep(candidates(1...2))
        pool.show(candidates(1...1)[0].reference)

        pool.keep([])

        XCTAssertTrue(pool.pages.isEmpty)
        XCTAssertNil(pool.shown)
        XCTAssertEqual(pool.loadingCount, 0)
    }

    @MainActor
    func testAPullRequestChangedOnGitHubLoadsAgainOnlyOnceItLeavesThePane() {
        let pool = PullRequestWebPool()
        let shown = candidates(1...1)[0]
        let hidden = candidates(2...2)[0]
        pool.keep([shown, hidden])
        pool.show(shown.reference)
        let later = Date(timeIntervalSince1970: 1_000)

        pool.keep([PullRequestWebCandidate(reference: shown.reference, version: later),
                   PullRequestWebCandidate(reference: hidden.reference, version: later)])

        XCTAssertTrue(pool.pages[shown.reference]!.isStale)
        XCTAssertFalse(pool.pages[hidden.reference]!.isStale)

        pool.show(hidden.reference)

        XCTAssertFalse(pool.pages[shown.reference]!.isStale)
        XCTAssertEqual(pool.pages[shown.reference]!.version, later)
        pool.removeAll()
    }

    @MainActor
    func testOpeningTheDiffShowsItsWebView() {
        let pool = PullRequestWebPool()
        let reference = candidates(1...1)[0].reference
        pool.show(reference)

        pool.open(.files, in: reference)

        XCTAssertEqual(pool.pages[reference]!.visiblePage, .files)
        XCTAssertTrue(pool.pages[reference]!.visibleSession === pool.pages[reference]!.files)
        pool.removeAll()
    }

    @MainActor
    func testClickingTheOtherPagesTabAsksForItsWebView() async throws {
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 12)
        let session = PullRequestWebSession(interceptedLinks: ["/acme/widgets/pull/12/files": .files])
        var opened: [PullRequestWebPage] = []
        session.onOpenPage = { opened.append($0) }
        session.webView.loadHTMLString("""
            <a id="files" href="/acme/widgets/pull/12/files">Files changed</a>
            <a id="commits" href="/acme/widgets/pull/12/commits">Commits</a>
            """, baseURL: reference.webURL)
        try await waitUntil { !session.webView.isLoading && session.webView.url != nil }

        _ = try await session.webView.evaluateJavaScript("document.getElementById('files').click(); true")
        try await waitUntil { !opened.isEmpty }

        XCTAssertEqual(opened, [.files])
        XCTAssertEqual(session.webView.url, reference.webURL)
    }

    func testInterceptionScriptListsTheOtherPagesPaths() {
        let script = PullRequestWebSession.linkInterceptionScript(for: ["/acme/widgets/pull/12/files": .files])

        XCTAssertTrue(script.contains(#"{"\/acme\/widgets\/pull\/12\/files":"files"}"#)
                      || script.contains(#"{"/acme/widgets/pull/12/files":"files"}"#), script)
    }

    private func candidates(_ numbers: ClosedRange<Int>) -> [PullRequestWebCandidate] {
        numbers.map {
            PullRequestWebCandidate(reference: PullRequestReference(repoFullName: "acme/widgets", number: $0),
                                    version: Date(timeIntervalSince1970: TimeInterval($0)))
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
