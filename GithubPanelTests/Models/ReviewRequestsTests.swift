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
}
