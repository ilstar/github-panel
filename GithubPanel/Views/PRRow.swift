import SwiftUI

struct PRRow: View {
    let pr: PullRequestRow
    let isSelected: Bool
    let relativeFormatter: RelativeDateTimeFormatter
    let now: Date

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                statusIcon
                summary
            }

            Spacer(minLength: 8)
        }
        .listRowBackground(isSelected: isSelected, isHovering: isHovering, isCard: true)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pr.title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
                .help(pr.title)

            RowSubtitle(text: "\(pr.repoFullName)#\(String(pr.number))",
                        detail: "Updated \(relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: now))")

            HStack(spacing: 6) {
                StatusChip(symbolName: "hammer.fill",
                           color: pr.status.tint,
                           help: pr.status.descriptionText)
                StatusChip(symbolName: "person.fill",
                           color: reviewIndicator.color,
                           help: reviewHelp)
            }
            .padding(.top, 3)
        }
    }

    private var reviewIndicator: ReviewIndicator {
        pr.reviewStatus.indicator
    }

    private var reviewHelp: String {
        [reviewIndicator.title + ".", pr.reviewStatus.helpText].compactMap { $0 }.joined(separator: "\n")
    }

    private var statusIcon: some View {
        let state = PullRequestState(pr)
        return RowIcon(systemName: state.symbolName, color: state.tint, inCircle: true)
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
            .frame(height: 18)
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
        case .autoMerge: return Theme.branch
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
