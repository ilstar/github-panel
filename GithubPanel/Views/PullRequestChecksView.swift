import SwiftUI
import AppKit

/// The head commit's checks, failing first: each check's name, how long it ran, a link to its log,
/// and buttons that run failed checks again.
struct PullRequestChecksView: View {
    /// Nil while the checks load.
    let checks: PullRequestChecks?
    /// Reruns GitHub has not answered yet.
    let rerunsInFlight: Set<CheckRerun>
    let onRerun: (CheckRerun) -> Void
    let onRerunFailed: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let checks {
                    header(checks)
                    if !checks.checks.isEmpty {
                        // Ticks each second so running checks show how long they have taken.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            VStack(spacing: 0) {
                                ForEach(Array(checks.checks.enumerated()), id: \.element.id) { index, check in
                                    if index > 0 {
                                        Rectangle().fill(Theme.hairline).frame(height: 1)
                                    }
                                    PullRequestCheckRow(check: check,
                                                        now: context.date,
                                                        isRerunning: check.rerun.map(rerunsInFlight.contains) ?? false,
                                                        onRerun: check.rerun.map { rerun in { onRerun(rerun) } })
                                }
                            }
                            .conversationCard()
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 900, alignment: .leading)
            .background(PageScrollAnchor())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ checks: PullRequestChecks) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbolName(for: checks))
                .foregroundStyle(Self.tint(for: checks))
            Text(checks.summary)
                .prFont(.callout, weight: .semibold)
            Spacer(minLength: 12)
            let reruns = checks.failedReruns
            if !reruns.isEmpty {
                let isBusy = reruns.allSatisfy(rerunsInFlight.contains)
                Button(action: onRerunFailed) {
                    Label(isBusy ? "Re-running..." : "Re-run failed", systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)
                .help("Run every failed check again")
            }
        }
    }

    static func symbolName(for checks: PullRequestChecks) -> String {
        if checks.count(.failure) > 0 { return "xmark.circle.fill" }
        if checks.count(.pending) > 0 { return "clock.circle.fill" }
        return checks.checks.isEmpty ? "minus.circle.fill" : "checkmark.circle.fill"
    }

    static func tint(for checks: PullRequestChecks) -> Color {
        if checks.count(.failure) > 0 { return Theme.red }
        if checks.count(.pending) > 0 { return Theme.amber }
        return checks.checks.isEmpty ? .secondary : Theme.green
    }
}

struct PullRequestCheckRow: View {
    let check: PullRequestCheck
    let now: Date
    var isRerunning = false
    /// Runs the check's failed jobs again. Nil when GitHub cannot rerun it, such as a commit status.
    var onRerun: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbolName(for: check.outcome))
                .foregroundStyle(Self.tint(for: check.outcome))
                .accessibilityLabel(Self.outcomeLabel(for: check.outcome))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(check.displayName)
                        .prFont(.callout, weight: check.outcome == .failure ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if check.isRequired {
                        Text("Required")
                            .prFont(.caption2, weight: .medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
                if let summary = check.summary {
                    Text(summary)
                        .prFont(.caption1)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let duration = check.duration(now: now) {
                Text(PullRequestCheck.formatDuration(duration))
                    .prFont(.caption1)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(check.outcome == .pending ? "Running for" : "Ran for")
            }

            if check.outcome == .failure, let onRerun {
                Button(action: onRerun) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(isRerunning)
                .help(Self.rerunHelp(for: check))
                .accessibilityLabel("Re-run")
            }

            if let url = check.detailsURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text("Log")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .help("Open the check's log on GitHub")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    static func rerunHelp(for check: PullRequestCheck) -> String {
        switch check.rerun {
        case .workflowRun: return "Re-run the failed jobs in \(check.workflowName ?? "this workflow")"
        case .checkSuite, nil: return "Re-run \(check.workflowName ?? "this check suite")"
        }
    }

    static func symbolName(for outcome: PullRequestCheck.Outcome) -> String {
        switch outcome {
        case .failure: return "xmark.circle.fill"
        case .pending: return "clock.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        }
    }

    static func tint(for outcome: PullRequestCheck.Outcome) -> Color {
        switch outcome {
        case .failure: return Theme.red
        case .pending: return Theme.amber
        case .success: return Theme.green
        case .skipped: return .secondary
        }
    }

    static func outcomeLabel(for outcome: PullRequestCheck.Outcome) -> String {
        switch outcome {
        case .failure: return "Failed"
        case .pending: return "In progress"
        case .success: return "Passed"
        case .skipped: return "Skipped"
        }
    }
}
