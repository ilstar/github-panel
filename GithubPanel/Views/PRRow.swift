import SwiftUI

struct PRRow: View {
    let pr: PullRequestRow
    let isSelected: Bool
    let relativeFormatter: RelativeDateTimeFormatter
    let now: Date

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            summary
            Spacer(minLength: 0)
        }
        // A little roomier than the other tabs' rows, so the chips sit comfortably under the title.
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .listRowBackground(isSelected: isSelected, isHovering: isHovering, isCard: true)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(pr.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .help(pr.title)

            // The repository gives way first when the row is narrow, so the age and chips stay whole.
            HStack(spacing: 8) {
                Text("\(pr.repoFullName)#\(String(pr.number))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(CompactAge.string(from: pr.updatedAt, to: now))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .help("Updated \(relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: now))")
                statusChips
            }
            .font(.system(size: 11.5))
        }
    }

    /// Checks and reviews, beside the pull request's number.
    private var statusChips: some View {
        HStack(spacing: 6) {
            StatusChip(symbolName: "hammer.fill",
                       color: pr.status.tint,
                       help: pr.status.descriptionText)
            StatusChip(symbolName: "person.fill",
                       color: reviewIndicator.color,
                       help: reviewHelp)
        }
        .fixedSize()
    }

    private var reviewIndicator: ReviewIndicator {
        pr.reviewStatus.indicator
    }

    private var reviewHelp: String {
        [reviewIndicator.title + ".", pr.reviewStatus.helpText].compactMap { $0 }.joined(separator: "\n")
    }

    private var statusIcon: some View {
        let state = PullRequestState(pr)
        return RowIcon(systemName: state.symbolName, color: state.tint, inCircle: true, diameter: 22)
            .help(state.title)
            .accessibilityLabel(state.title)
    }
}

/// A small capsule on a My PRs card: a glyph for what it is about, such as checks or reviews, in the
/// color of how that stands. The tooltip spells the state out.
struct StatusChip: View {
    let symbolName: String
    let color: Color
    let help: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help)
    }
}

extension PullRequestState {
    /// A bare glyph, drawn white on the row's colored disc.
    var symbolName: String {
        switch self {
        case .conflict: return "exclamationmark"
        case .draft: return "pencil"
        case .queued: return "arrow.right.to.line"
        case .autoMerge: return "bolt.fill"
        case .open: return "arrow.triangle.pull"
        }
    }

    var tint: Color {
        switch self {
        case .conflict: return Theme.orange
        case .draft: return .secondary
        case .queued: return Theme.purple
        case .autoMerge: return Theme.amber
        case .open: return Theme.green
        }
    }
}

extension ReviewIndicator {
    var color: Color {
        switch self {
        case .none: return .secondary
        case .waiting: return Theme.amber
        case .approved: return Theme.green
        case .changesRequested: return Theme.red
        }
    }
}

extension CheckState {
    var symbolName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .noChecks: return "minus.circle.fill"
        case .failure, .error: return "xmark.circle.fill"
        case .pending: return "clock.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return Theme.green
        case .noChecks, .unknown: return .secondary
        case .failure, .error: return Theme.red
        case .pending: return Theme.amber
        }
    }
}

extension ReviewBadge {
    var color: Color {
        switch self {
        case .approved: return Theme.green
        case .changesRequested: return Theme.red
        case .awaitingReview, .needsReview: return Theme.amber
        }
    }
}
