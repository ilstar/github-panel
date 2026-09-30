import Foundation

/// How GitHub starts one check again.
enum CheckRerun: Hashable {
    /// A GitHub Actions workflow run, whose failed jobs run again. The run's database ID.
    case workflowRun(Int)
    /// Another app's check suite, which GitHub asks the app to run again. Node IDs of the repository and the suite.
    case checkSuite(repositoryID: String, suiteID: String)
}

/// One check run or commit status on the pull request's head commit.
struct PullRequestCheck: Identifiable, Equatable {
    enum Outcome: Equatable {
        case failure
        case pending
        case success
        /// Skipped, neutral, or stale: finished without passing or failing.
        case skipped
    }

    let id: String
    let name: String
    /// The workflow or app that ran the check, such as "CI". Nil for commit statuses.
    let workflowName: String?
    let outcome: Outcome
    /// GitHub's short summary, such as a status's description or "Cancelled".
    let summary: String?
    let startedAt: Date?
    let completedAt: Date?
    /// The check's page on GitHub, which shows its log.
    let detailsURL: URL?
    var isRequired = false
    /// How to run the check again. Nil for commit statuses, which only their sender can rerun.
    var rerun: CheckRerun?

    /// How long the check ran, or has run so far. Nil before it starts.
    func duration(now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (completedAt ?? now).timeIntervalSince(startedAt))
    }

    /// "Tests" or "CI / Tests".
    var displayName: String {
        guard let workflowName, !workflowName.isEmpty, workflowName != name else { return name }
        return "\(workflowName) / \(name)"
    }

    /// Maps a check run's status and conclusion, like GitHub's checks list.
    static func outcome(status: String, conclusion: String?) -> Outcome {
        guard status == "COMPLETED" else { return .pending }
        switch conclusion {
        case "SUCCESS": return .success
        case "FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED": return .failure
        default: return .skipped
        }
    }

    /// Maps a commit status's state.
    static func outcome(statusState: String) -> Outcome {
        switch statusState {
        case "SUCCESS": return .success
        case "FAILURE", "ERROR": return .failure
        default: return .pending
        }
    }

    /// "42s", "3m 05s", or "1h 02m".
    static func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return String(format: "%dm %02ds", seconds / 60, seconds % 60) }
        return String(format: "%dh %02dm", seconds / 3_600, seconds % 3_600 / 60)
    }
}

/// The checks on a pull request's head commit, failing first, like GitHub's merge box.
struct PullRequestChecks: Equatable {
    let checks: [PullRequestCheck]

    static let empty = PullRequestChecks(checks: [])

    init(checks: [PullRequestCheck]) {
        self.checks = checks.enumerated().sorted { lhs, rhs in
            let left = Self.rank(lhs.element.outcome), right = Self.rank(rhs.element.outcome)
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    var failed: [PullRequestCheck] { checks.filter { $0.outcome == .failure } }

    func count(_ outcome: PullRequestCheck.Outcome) -> Int {
        checks.filter { $0.outcome == outcome }.count
    }

    /// What to rerun for every failing check that can be rerun, once each, in list order.
    /// A workflow run with several failing jobs is rerun once, which reruns all of them.
    var failedReruns: [CheckRerun] {
        var seen: Set<CheckRerun> = []
        return failed.compactMap(\.rerun).filter { seen.insert($0).inserted }
    }

    /// "2 failing, 1 in progress, 9 successful", leaving out zeros.
    var summary: String {
        let parts = [(count(.failure), "failing"), (count(.pending), "in progress"),
                     (count(.success), "successful"), (count(.skipped), "skipped")]
        let text = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        return text.isEmpty ? "No checks reported" : text
    }

    private static func rank(_ outcome: PullRequestCheck.Outcome) -> Int {
        switch outcome {
        case .failure: return 0
        case .pending: return 1
        case .success: return 2
        case .skipped: return 3
        }
    }
}
