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

    private func state(_ requests: ReviewRequests, isLoading: Bool, error: String?, hasLoaded: Bool) -> ReviewRequestsDisplayState {
        ReviewRequestsDisplayState(requests: requests, isLoading: isLoading, error: error, hasLoaded: hasLoaded)
    }
}
