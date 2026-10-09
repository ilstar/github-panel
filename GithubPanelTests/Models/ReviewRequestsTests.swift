import XCTest
@testable import GithubPanel

final class ReviewRequestsTests: XCTestCase {
    func testTeamRequestsExcludeDirectRequests() {
        let requests = ReviewRequests(direct: [reviewRequestRow(number: 2)],
                                      all: [reviewRequestRow(number: 1), reviewRequestRow(number: 2), reviewRequestRow(number: 3)])

        XCTAssertEqual(requests.fromMe.map(\.number), [2])
        XCTAssertEqual(requests.fromMyTeams.map(\.number), [1, 3])
        XCTAssertEqual(requests.rows(in: .fromMe).map(\.number), [2])
        XCTAssertEqual(requests.rows(in: .fromMyTeams).map(\.number), [1, 3])
        XCTAssertEqual(requests.rows.map(\.number), [2, 1, 3])
    }

    func testGroupsListRequestsFromMeFirst() {
        XCTAssertEqual(ReviewRequestGroup.allCases, [.fromMe, .fromMyTeams])
        XCTAssertEqual(ReviewRequestGroup.allCases.map(\.title), ["Requested from me", "Requested from my teams"])
    }

    func testRemovingDropsRowsFromBothGroupsAndKeepsTheSSONote() {
        let url = URL(string: "https://github.com/orgs/acme/sso")!
        let requests = ReviewRequests(fromMe: [reviewRequestRow(number: 1), reviewRequestRow(number: 2)],
                                      fromMyTeams: [reviewRequestRow(number: 3)],
                                      ssoAuthorizationURL: url)

        let remaining = requests.removing { $0.number != 2 }

        XCTAssertEqual(remaining.rows.map(\.number), [2])
        XCTAssertEqual(remaining.ssoAuthorizationURL, url)
    }

    func testHiddenRequestHidesOnlyTheSameCommitAndRequest() {
        var row = reviewRequestRow(number: 1)
        row.headSHA = "sha-1"
        row.requestedAt = Date(timeIntervalSince1970: 100)
        let hidden = HiddenReviewRequest(row)

        XCTAssertTrue(hidden.hides(row))
        var pushed = row
        pushed.headSHA = "sha-2"
        XCTAssertFalse(hidden.hides(pushed))
        var reRequested = row
        reRequested.requestedAt = Date(timeIntervalSince1970: 200)
        XCTAssertFalse(hidden.hides(reRequested))
    }

        func testDisplayStatePrefersRowsThenErrorThenLoading() {
        let rows = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])

        XCTAssertEqual(state(rows, isLoading: true, error: "boom", hasLoaded: true), .list)
        XCTAssertEqual(state(.empty, isLoading: false, error: "boom", hasLoaded: true), .failed("boom"))
        XCTAssertEqual(state(.empty, isLoading: false, error: nil, hasLoaded: false), .loading)
        XCTAssertEqual(state(.empty, isLoading: true, error: nil, hasLoaded: true), .loading)
        XCTAssertEqual(state(.empty, isLoading: false, error: nil, hasLoaded: true), .empty)
    }

    func testPageSpansTheEndOfRequestsFromMeAndTheStartOfTeamRequests() {
        let requests = ReviewRequests(fromMe: (1...3).map { reviewRequestRow(number: $0) },
                                      fromMyTeams: (4...7).map { reviewRequestRow(number: $0) })

        let first = ReviewRequestsPage(requests: requests, page: 1, size: 2)
        XCTAssertEqual(first.fromMe.map(\.number), [1, 2])
        XCTAssertEqual(first.fromMyTeams.map(\.number), [])
        XCTAssertEqual(first.pageCount, 4)
        XCTAssertEqual(first.rangeText, "1-2 of 7")
        XCTAssertFalse(first.canGoToPreviousPage)
        XCTAssertTrue(first.canGoToNextPage)

        let second = ReviewRequestsPage(requests: requests, page: 2, size: 2)
        XCTAssertEqual(second.fromMe.map(\.number), [3])
        XCTAssertEqual(second.fromMyTeams.map(\.number), [4])
        XCTAssertEqual(second.rows.map(\.number), [3, 4])
        XCTAssertEqual(second.rangeText, "3-4 of 7")

        let last = ReviewRequestsPage(requests: requests, page: 4, size: 2)
        XCTAssertEqual(last.rows.map(\.number), [7])
        XCTAssertEqual(last.rangeText, "7-7 of 7")
        XCTAssertTrue(last.canGoToPreviousPage)
        XCTAssertFalse(last.canGoToNextPage)
    }

    func testPageIsClampedWhenRowsGoAway() {
        let requests = ReviewRequests(fromMe: (1...3).map { reviewRequestRow(number: $0) }, fromMyTeams: [])

        XCTAssertEqual(ReviewRequestsPage(requests: requests, page: 5, size: 2).page, 2)
        XCTAssertEqual(ReviewRequestsPage(requests: requests, page: 0, size: 2).page, 1)
        let empty = ReviewRequestsPage(requests: .empty, page: 3, size: 2)
        XCTAssertEqual(empty.page, 1)
        XCTAssertEqual(empty.pageCount, 1)
        XCTAssertFalse(empty.hasMultiplePages)
        XCTAssertEqual(empty.rows, [])
    }

    func testOnePageWhenEverythingFits() {
        let requests = ReviewRequests(fromMe: (1...2).map { reviewRequestRow(number: $0) },
                                      fromMyTeams: [reviewRequestRow(number: 3)])

        let page = ReviewRequestsPage(requests: requests, page: 1)
        XCTAssertFalse(page.hasMultiplePages)
        XCTAssertEqual(page.rows.map(\.number), [1, 2, 3])
        XCTAssertEqual(ReviewRequestsPage.defaultSize, 10)
    }

    func testPageContainingFindsARequestInEitherGroup() {
        let requests = ReviewRequests(fromMe: (1...3).map { reviewRequestRow(number: $0) },
                                      fromMyTeams: (4...5).map { reviewRequestRow(number: $0) })

        XCTAssertEqual(ReviewRequestsPage.page(containing: "acme/widgets#1", in: requests, size: 2), 1)
        XCTAssertEqual(ReviewRequestsPage.page(containing: "acme/widgets#3", in: requests, size: 2), 2)
        XCTAssertEqual(ReviewRequestsPage.page(containing: "acme/widgets#5", in: requests, size: 2), 3)
        XCTAssertNil(ReviewRequestsPage.page(containing: "acme/widgets#9", in: requests, size: 2))
    }

    func testGroupHeadingsShowOnPagesWithTheirRowsAndEmptyGroupsAtTheirEnd() {
        let requests = ReviewRequests(fromMe: (1...3).map { reviewRequestRow(number: $0) },
                                      fromMyTeams: [reviewRequestRow(number: 4)])
        let first = ReviewRequestsPage(requests: requests, page: 1, size: 2)
        let second = ReviewRequestsPage(requests: requests, page: 2, size: 2)

        XCTAssertTrue(first.showsGroup(.fromMe, in: requests))
        XCTAssertFalse(first.showsGroup(.fromMyTeams, in: requests))
        XCTAssertTrue(second.showsGroup(.fromMe, in: requests))
        XCTAssertTrue(second.showsGroup(.fromMyTeams, in: requests))

        let onlyTeams = ReviewRequests(fromMe: [], fromMyTeams: (1...3).map { reviewRequestRow(number: $0) })
        XCTAssertTrue(ReviewRequestsPage(requests: onlyTeams, page: 1, size: 2).showsGroup(.fromMe, in: onlyTeams))
        XCTAssertFalse(ReviewRequestsPage(requests: onlyTeams, page: 2, size: 2).showsGroup(.fromMe, in: onlyTeams))

        let onlyMine = ReviewRequests(fromMe: (1...3).map { reviewRequestRow(number: $0) }, fromMyTeams: [])
        XCTAssertFalse(ReviewRequestsPage(requests: onlyMine, page: 1, size: 2).showsGroup(.fromMyTeams, in: onlyMine))
        XCTAssertTrue(ReviewRequestsPage(requests: onlyMine, page: 2, size: 2).showsGroup(.fromMyTeams, in: onlyMine))
    }

    private func state(_ requests: ReviewRequests, isLoading: Bool, error: String?, hasLoaded: Bool) -> ReviewRequestsDisplayState {
        ReviewRequestsDisplayState(requests: requests, isLoading: isLoading, error: error, hasLoaded: hasLoaded)
    }
}
