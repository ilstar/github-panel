import SwiftUI

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

/// The Checks section of the conversation's sidebar: the first few checks, failing first, and a button
/// that opens the Checks tab for the rest.
struct PullRequestChecksSection: View {
    /// Nil while the checks load.
    let checks: PullRequestChecks?
    let onShowAll: () -> Void

    static let visibleLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarSectionTitle(text: "Checks")
            if let checks {
                if checks.checks.isEmpty {
                    Text("No checks reported")
                        .prFont(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Self.visibleChecks(checks)) { check in
                            HStack(spacing: 8) {
                                Image(systemName: PullRequestCheckRow.symbolName(for: check.outcome))
                                    .foregroundStyle(PullRequestCheckRow.tint(for: check.outcome))
                                    .accessibilityLabel(PullRequestCheckRow.outcomeLabel(for: check.outcome))
                                Text(check.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(check.displayName)
                            }
                            .prFont(.callout)
                        }
                    }
                    Button(Self.showAllTitle(checks), action: onShowAll)
                        .buttonStyle(.plain)
                        .prFont(.callout)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .sidebarSection()
    }

    static func visibleChecks(_ checks: PullRequestChecks) -> [PullRequestCheck] {
        Array(checks.checks.prefix(visibleLimit))
    }

    /// "View all checks", or "Show all 12 checks" when some are hidden.
    static func showAllTitle(_ checks: PullRequestChecks) -> String {
        checks.checks.count > visibleLimit ? "Show all \(checks.checks.count) checks" : "View all checks"
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
