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

    func testConversationTabBadgeCountsComments() {
        XCTAssertNil(PullRequestDetailView.conversationBadge(nil))
        XCTAssertNil(PullRequestDetailView.conversationBadge(0))
        XCTAssertEqual(PullRequestDetailView.conversationBadge(3), .count(3))
    }

    func testSidebarChecksFoldALongListFailingFirst() {
        let many = PullRequestChecks(checks: (0..<9).map { check("ok\($0)", .success) } + [check("bad", .failure)])
        let folded = PullRequestChecksSection.visibleChecks(many, isExpanded: false)
        XCTAssertEqual(folded.count, PullRequestChecksSection.collapsedLimit)
        XCTAssertEqual(folded.first?.name, "bad")
        XCTAssertEqual(PullRequestChecksSection.visibleChecks(many, isExpanded: true).count, 10)
        XCTAssertEqual(PullRequestChecksSection.toggleTitle(many, isExpanded: false), "Show all 10 checks")
        XCTAssertEqual(PullRequestChecksSection.toggleTitle(many, isExpanded: true), "Show less")

        let few = PullRequestChecks(checks: [check("a", .success), check("b", .pending)])
        XCTAssertEqual(PullRequestChecksSection.visibleChecks(few, isExpanded: false).map(\.name), ["b", "a"])
        XCTAssertNil(PullRequestChecksSection.toggleTitle(few, isExpanded: false))
    }

    func testCheckRowTooltipSaysWhatTheCheckDidAndThatAClickOpensItsLog() {
        let start = Date(timeIntervalSince1970: 1_000)
        let job = PullRequestCheck(id: "a", name: "Tests", workflowName: "CI", outcome: .failure, summary: "Cancelled",
                                   startedAt: start, completedAt: start.addingTimeInterval(185),
                                   detailsURL: URL(string: "https://github.com/acme/widgets/runs/1"), isRequired: true)
        XCTAssertEqual(PullRequestCheckRow.help(for: job, now: start),
                       "CI / Tests (Required)\nCancelled\nRan for 3m 05s\nClick to open the log on GitHub")
        XCTAssertEqual(PullRequestCheckRow.help(for: check("lint", .pending), now: start), "lint")
    }

    func testSidebarChangesLabelCountsFiles() {
        XCTAssertEqual(PullRequestChangesSection.filesLabel(1), "1 file")
        XCTAssertEqual(PullRequestChangesSection.filesLabel(3), "3 files")
    }
}
