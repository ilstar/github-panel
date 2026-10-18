import XCTest
@testable import GithubPanel

final class PullRequestWebPreloadTests: XCTestCase {
    private let reference = PullRequestReference(repoFullName: "acme/widgets", number: 12)

    func testPagesLiveUnderThePullRequestsURL() {
        XCTAssertEqual(PullRequestWebPage.conversation.url(for: reference).absoluteString,
                       "https://github.com/acme/widgets/pull/12")
        XCTAssertEqual(PullRequestWebPage.files.url(for: reference).absoluteString,
                       "https://github.com/acme/widgets/pull/12/files")
    }

    func testRecognizesThePullRequestsOwnPages() {
        let page = { (link: String) in PullRequestWebPage.page(of: URL(string: link), for: self.reference) }

        XCTAssertEqual(page("https://github.com/acme/widgets/pull/12"), .conversation)
        XCTAssertEqual(page("https://github.com/acme/widgets/pull/12/"), .conversation)
        XCTAssertEqual(page("https://github.com/acme/widgets/pull/12/files"), .files)
        XCTAssertEqual(page("https://github.com/acme/widgets/pull/12/changes"), .files)
    }

    func testOtherPagesAndLinksToOneSpotAreNotThePullRequestsPages() {
        let page = { (link: String) in PullRequestWebPage.page(of: URL(string: link), for: self.reference) }

        XCTAssertNil(page("https://github.com/acme/widgets/pull/12/commits"))
        XCTAssertNil(page("https://github.com/acme/widgets/pull/13/files"))
        XCTAssertNil(page("https://github.com/acme/widgets/pull/12/files?w=1"))
        XCTAssertNil(page("https://github.com/acme/widgets/pull/12#issuecomment-1"))
        XCTAssertNil(page("https://example.com/acme/widgets/pull/12"))
        XCTAssertNil(PullRequestWebPage.page(of: nil, for: reference))
    }

    func testAPageIsShownOnlyAtItsURLWithASuccessfulResponse() {
        let url = URL(string: "https://github.com/acme/widgets/pull/12/changes")

        XCTAssertTrue(PullRequestWebPage.files.isShown(at: url, statusCode: 200, for: reference))
        XCTAssertTrue(PullRequestWebPage.files.isShown(at: url, statusCode: nil, for: reference))
        XCTAssertFalse(PullRequestWebPage.files.isShown(at: url, statusCode: 404, for: reference))
        XCTAssertFalse(PullRequestWebPage.files.isShown(at: url, statusCode: 500, for: reference))
        XCTAssertFalse(PullRequestWebPage.conversation.isShown(at: url, statusCode: 200, for: reference))
        XCTAssertFalse(PullRequestWebPage.conversation.isShown(
            at: URL(string: "https://github.com/login?return_to=%2Facme%2Fwidgets%2Fpull%2F12"),
            statusCode: 200, for: reference))
        XCTAssertFalse(PullRequestWebPage.conversation.isShown(at: nil, statusCode: nil, for: reference))
    }

    func testPlanStartsAtTheSelectionAndWorksOutwardBelowFirst() {
        let rows = candidates(1...5)

        let plan = PullRequestWebPreload.plan(selected: rows[2].reference, visible: rows, other: [])

        XCTAssertEqual(plan.map(\.reference.number), [3, 4, 2, 5, 1])
    }

    func testPlanTakesTheVisibleListBeforeTheOtherOne() {
        let plan = PullRequestWebPreload.plan(selected: nil, visible: candidates(1...2), other: candidates(10...11))

        XCTAssertEqual(plan.map(\.reference.number), [1, 2, 10, 11])
    }

    func testPlanListsAPullRequestOnBothListsOnce() {
        let plan = PullRequestWebPreload.plan(selected: nil, visible: candidates(1...2), other: candidates(2...3))

        XCTAssertEqual(plan.map(\.reference.number), [1, 2, 3])
    }

    func testPlanStopsAtCapacityButKeepsTheSelection() {
        let rows = candidates(1...10)

        let plan = PullRequestWebPreload.plan(selected: rows[9].reference, visible: rows, other: [], capacity: 3)

        XCTAssertEqual(plan.map(\.reference.number), [10, 9, 8])
    }

    func testPlanPutsASelectionFromNeitherListFirst() {
        let history = PullRequestReference(repoFullName: "acme/widgets", number: 99)

        let plan = PullRequestWebPreload.plan(selected: history, visible: [], other: candidates(1...2))

        XCTAssertEqual(plan, [PullRequestWebCandidate(reference: history, version: nil)] + candidates(1...2))
    }

    func testPlanKeepsTheSelectionsVersionFromTheOtherList() {
        let rows = candidates(1...2)

        let plan = PullRequestWebPreload.plan(selected: rows[1].reference, visible: [], other: rows)

        XCTAssertEqual(plan, [rows[1], rows[0]])
    }

    private func candidates(_ numbers: ClosedRange<Int>) -> [PullRequestWebCandidate] {
        numbers.map {
            PullRequestWebCandidate(reference: PullRequestReference(repoFullName: "acme/widgets", number: $0),
                                    version: Date(timeIntervalSince1970: TimeInterval($0)))
        }
    }
}
