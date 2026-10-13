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
    func testSessionLoadsAPageOnlyWhenItChanges() {
        let session = PullRequestWebSession()
        let url = PullRequestReference(repoFullName: "acme/widgets", number: 12).webURL

        session.show(url)
        let first = session.webView.backForwardList.currentItem
        session.show(url)

        XCTAssertEqual(session.webView.backForwardList.currentItem, first)
    }
}
