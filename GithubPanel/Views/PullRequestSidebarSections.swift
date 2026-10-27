import SwiftUI
import AppKit

/// The Changes section of the conversation's sidebar: how many files changed, and the lines added and removed.
struct PullRequestChangesSection: View {
    let detail: PullRequestDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarSectionTitle(text: "Changes")
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(Self.filesLabel(detail.changedFiles))
                Text("+\(detail.additions)")
                    .foregroundStyle(DiffColors.additionText)
                Text("−\(detail.deletions)")
                    .foregroundStyle(DiffColors.deletionText)
            }
            .prFont(.callout)
            .monospacedDigit()
        }
        .sidebarSection()
    }

    static func filesLabel(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
}

/// The Checks section of the conversation's sidebar: every check on the head commit, failing first. Each one
/// opens its log on GitHub, failed ones can run again, and a long list folds after the first few.
struct PullRequestChecksSection: View {
    /// Nil while the checks load.
    let checks: PullRequestChecks?
    /// Reruns GitHub has not answered yet.
    var rerunsInFlight: Set<CheckRerun> = []
    var onRerun: (CheckRerun) -> Void = { _ in }
    var onRerunFailed: () -> Void = {}

    @State private var isExpanded = false

    static let collapsedLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                SidebarSectionTitle(text: "Checks")
                Spacer(minLength: 4)
                if let checks, !checks.failedReruns.isEmpty {
                    let isBusy = checks.failedReruns.allSatisfy(rerunsInFlight.contains)
                    Button(action: onRerunFailed) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(isBusy ? "Re-running..." : "Re-run failed checks")
                    .accessibilityLabel("Re-run failed checks")
                }
            }

            if let checks {
                if checks.checks.isEmpty {
                    Text("No checks reported")
                        .prFont(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(checks.summary)
                        .prFont(.caption1)
                        .foregroundStyle(.secondary)

                    // Ticks each second so a running check's tooltip shows how long it has taken.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Self.visibleChecks(checks, isExpanded: isExpanded)) { check in
                                PullRequestCheckRow(check: check,
                                                    now: context.date,
                                                    isRerunning: check.rerun.map(rerunsInFlight.contains) ?? false,
                                                    onRerun: check.rerun.map { rerun in { onRerun(rerun) } })
                            }
                        }
                    }
                    .padding(.horizontal, -6)

                    if let title = Self.toggleTitle(checks, isExpanded: isExpanded) {
                        Button(title) { isExpanded.toggle() }
                            .buttonStyle(.plain)
                            .prFont(.callout)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .sidebarSection()
    }

    static func visibleChecks(_ checks: PullRequestChecks, isExpanded: Bool) -> [PullRequestCheck] {
        isExpanded ? checks.checks : Array(checks.checks.prefix(collapsedLimit))
    }

    /// "Show all 12 checks" or "Show less" when the list is long enough to fold, else nil.
    static func toggleTitle(_ checks: PullRequestChecks, isExpanded: Bool) -> String? {
        guard checks.checks.count > collapsedLimit else { return nil }
        return isExpanded ? "Show less" : "Show all \(checks.checks.count) checks"
    }
}

/// One check in the sidebar: its outcome and name, opening its log on GitHub when clicked. A failed check
/// that can run again gets a rerun button on hover.
struct PullRequestCheckRow: View {
    let check: PullRequestCheck
    let now: Date
    var isRerunning = false
    /// Runs the check's failed jobs again. Nil when GitHub cannot rerun it, such as a commit status.
    var onRerun: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if let url = check.detailsURL { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.symbolName(for: check.outcome))
                        .foregroundStyle(Self.tint(for: check.outcome))
                        .accessibilityLabel(Self.outcomeLabel(for: check.outcome))
                    Text(check.displayName)
                        .fontWeight(check.outcome == .failure ? .medium : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .prFont(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(check.detailsURL == nil)
            .help(Self.help(for: check, now: now))

            if check.outcome == .failure, let onRerun, isHovering || isRerunning {
                Button(action: onRerun) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRerunning)
                .help(Self.rerunHelp(for: check))
                .accessibilityLabel("Re-run")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering && check.detailsURL != nil ? Theme.tabHover : Color.clear)
        )
        .onHover { isHovering = $0 }
    }

    /// The tooltip: the full name, Required, GitHub's summary, how long it ran, and what a click does.
    static func help(for check: PullRequestCheck, now: Date) -> String {
        var lines = [check.isRequired ? "\(check.displayName) (Required)" : check.displayName]
        if let summary = check.summary { lines.append(summary) }
        if let duration = check.duration(now: now) {
            let verb = check.outcome == .pending ? "Running for" : "Ran for"
            lines.append("\(verb) \(PullRequestCheck.formatDuration(duration))")
        }
        if check.detailsURL != nil { lines.append("Click to open the log on GitHub") }
        return lines.joined(separator: "\n")
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

/// A section heading in the conversation's sidebar, like Reviewers.
struct SidebarSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .prFont(.callout, weight: .semibold)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// GitHub separates sidebar sections with a hairline.
    func sidebarSection() -> some View {
        padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
            }
    }
}
