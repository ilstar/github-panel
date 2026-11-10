import XCTest
@testable import GithubPanel

final class PullRequestRecordTests: XCTestCase {
    func testTheNewerStatusWinsWhicheverArrivesFirst() {
        let older = status("old", .failure, at: 1)
        let newer = status("new", .success, at: 2)

        XCTAssertEqual(older.merging(newer), newer)
        XCTAssertEqual(newer.merging(older), newer)
    }

    func testANewerLoadWithoutChecksKeepsTheStateOfTheSameHead() {
        let list = status("abc", .failure, at: 1)

        XCTAssertEqual(list.merging(status("abc", nil, at: 2)), status("abc", .failure, at: 2))
        XCTAssertEqual(status("abc", nil, at: 2).merging(list), status("abc", .failure, at: 2))
    }

    func testANewerHeadWithoutChecksIsPending() {
        var record = PullRequestRecord(openRow: row(number: 1, status: .failure),
                                       reviewRequestRow: reviewRequestRow(number: 1))
        record.observe(status("sha-1", .failure, at: 1))

        record.observe(status("merged", nil, at: 2))

        XCTAssertEqual(record.status, status("merged", nil, at: 2))
        XCTAssertEqual(record.shownOpenRow?.headSHA, "merged")
        XCTAssertEqual(record.shownOpenRow?.status, .pending)
        XCTAssertEqual(record.shownReviewRequestRow?.headSHA, "merged")
        XCTAssertEqual(record.shownReviewRequestRow?.checkState, .pending)
    }

    func testReviewRequestsShowNoChecksAsNil() {
        var record = PullRequestRecord(reviewRequestRow: reviewRequestRow(number: 1))

        record.observe(status("abc", .noChecks, at: 1))

        XCTAssertNil(record.shownReviewRequestRow?.checkState)
    }

    func testChecksAddUpLikeGitHubsRollup() {
        XCTAssertNil(PullRequestChecks.empty.checkState)
        XCTAssertEqual(checks(.success, .skipped).checkState, .success)
        XCTAssertEqual(checks(.success, .pending).checkState, .pending)
        XCTAssertEqual(checks(.pending, .failure).checkState, .failure)
        XCTAssertNil(PullRequestChecks(checks: Array(repeating: check(.success), count: PullRequestChecks.loadLimit))
            .checkState, "Checks past the limit didn't load, so they might fail")
    }

    private func status(_ headSHA: String, _ state: CheckState?, at time: TimeInterval) -> PullRequestStatus {
        PullRequestStatus(headSHA: headSHA, checkState: state, observedAt: Date(timeIntervalSince1970: time))
    }

    private func checks(_ outcomes: PullRequestCheck.Outcome...) -> PullRequestChecks {
        PullRequestChecks(checks: outcomes.map(check))
    }

    private func check(_ outcome: PullRequestCheck.Outcome) -> PullRequestCheck {
        PullRequestCheck(id: UUID().uuidString, name: "check", workflowName: nil, outcome: outcome, summary: nil,
                         startedAt: nil, completedAt: nil, detailsURL: nil, rerun: nil)
    }
}
