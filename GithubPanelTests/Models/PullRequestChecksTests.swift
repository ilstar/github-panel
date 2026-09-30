import XCTest
@testable import GithubPanel

final class PullRequestChecksTests: XCTestCase {
    private func check(_ id: String, _ outcome: PullRequestCheck.Outcome, rerun: CheckRerun? = nil) -> PullRequestCheck {
        PullRequestCheck(id: id, name: id, workflowName: nil, outcome: outcome, summary: nil,
                         startedAt: nil, completedAt: nil, detailsURL: nil, rerun: rerun)
    }

    func testChecksListFailingFirstThenPendingKeepingGitHubsOrderWithinEach() {
        let checks = PullRequestChecks(checks: [check("a", .success), check("b", .failure), check("c", .skipped),
                                                check("d", .pending), check("e", .failure)])
        XCTAssertEqual(checks.checks.map(\.id), ["b", "e", "d", "a", "c"])
    }

    func testSummaryCountsEachOutcomeAndLeavesOutZeros() {
        let checks = PullRequestChecks(checks: [check("a", .success), check("b", .failure), check("c", .failure),
                                                check("d", .pending)])
        XCTAssertEqual(checks.summary, "2 failing, 1 in progress, 1 successful")
        XCTAssertEqual(PullRequestChecks.empty.summary, "No checks reported")
    }

    func testFailedRerunsRunEachWorkflowOnceAndSkipStatuses() {
        let checks = PullRequestChecks(checks: [
            check("a", .failure, rerun: .workflowRun(1)),
            check("b", .failure, rerun: .workflowRun(1)),
            check("c", .failure, rerun: .checkSuite(repositoryID: "R", suiteID: "S")),
            check("d", .failure),
            check("e", .success, rerun: .workflowRun(2))
        ])
        XCTAssertEqual(checks.failedReruns, [.workflowRun(1), .checkSuite(repositoryID: "R", suiteID: "S")])
    }

    func testOutcomeMapsCheckRunConclusions() {
        XCTAssertEqual(PullRequestCheck.outcome(status: "IN_PROGRESS", conclusion: nil), .pending)
        XCTAssertEqual(PullRequestCheck.outcome(status: "QUEUED", conclusion: nil), .pending)
        XCTAssertEqual(PullRequestCheck.outcome(status: "COMPLETED", conclusion: "SUCCESS"), .success)
        XCTAssertEqual(PullRequestCheck.outcome(status: "COMPLETED", conclusion: "FAILURE"), .failure)
        XCTAssertEqual(PullRequestCheck.outcome(status: "COMPLETED", conclusion: "TIMED_OUT"), .failure)
        XCTAssertEqual(PullRequestCheck.outcome(status: "COMPLETED", conclusion: "CANCELLED"), .failure)
        XCTAssertEqual(PullRequestCheck.outcome(status: "COMPLETED", conclusion: "SKIPPED"), .skipped)
        XCTAssertEqual(PullRequestCheck.outcome(status: "COMPLETED", conclusion: "NEUTRAL"), .skipped)
    }

    func testOutcomeMapsStatusStates() {
        XCTAssertEqual(PullRequestCheck.outcome(statusState: "SUCCESS"), .success)
        XCTAssertEqual(PullRequestCheck.outcome(statusState: "ERROR"), .failure)
        XCTAssertEqual(PullRequestCheck.outcome(statusState: "FAILURE"), .failure)
        XCTAssertEqual(PullRequestCheck.outcome(statusState: "PENDING"), .pending)
    }

    func testDurationRunsToNowWhileTheCheckIsRunning() {
        let start = Date(timeIntervalSince1970: 1_000)
        let running = PullRequestCheck(id: "a", name: "a", workflowName: nil, outcome: .pending, summary: nil,
                                   startedAt: start, completedAt: nil, detailsURL: nil)
        XCTAssertEqual(running.duration(now: start.addingTimeInterval(75)), 75)
        let done = PullRequestCheck(id: "b", name: "b", workflowName: nil, outcome: .success, summary: nil,
                                    startedAt: start, completedAt: start.addingTimeInterval(30), detailsURL: nil)
        XCTAssertEqual(done.duration(now: start.addingTimeInterval(500)), 30)
        XCTAssertNil(check("c", .pending).duration(now: start))
    }

    func testFormatDuration() {
        XCTAssertEqual(PullRequestCheck.formatDuration(42), "42s")
        XCTAssertEqual(PullRequestCheck.formatDuration(185), "3m 05s")
        XCTAssertEqual(PullRequestCheck.formatDuration(3_720), "1h 02m")
    }

    func testDisplayNamePrefixesTheWorkflow() {
        let job = PullRequestCheck(id: "a", name: "Tests", workflowName: "CI", outcome: .success, summary: nil,
                                   startedAt: nil, completedAt: nil, detailsURL: nil)
        XCTAssertEqual(job.displayName, "CI / Tests")
        XCTAssertEqual(check("lint", .success).displayName, "lint")
    }

    func testChecksTabTitleCallsOutFailures() {
        XCTAssertEqual(PullRequestDetailView.checksTitle(nil), "Checks")
        XCTAssertEqual(PullRequestDetailView.checksTitle(.empty), "Checks")
        XCTAssertEqual(PullRequestDetailView.checksTitle(PullRequestChecks(checks: [check("a", .success), check("b", .pending)])),
                       "Checks 2")
        XCTAssertEqual(PullRequestDetailView.checksTitle(PullRequestChecks(checks: [check("a", .success), check("b", .failure)])),
                       "Checks 1 failing")
    }
}
