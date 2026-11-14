import SwiftUI

/// Lazy stacks can retain a row's content closure when its identity moves between groups. Observe the source
/// here and resolve the current row by ID, so both the card and its actions use the latest data.
struct ObservedPullRequestRow<Content: View>: View {
    @ObservedObject var monitor: PRMonitor
    let id: String
    @ViewBuilder var content: (PullRequestRow) -> Content

    var body: some View {
        if let pr = monitor.prRows.first(where: { $0.id == id }) {
            content(pr)
        }
    }
}

struct PRRow: View {
    let pr: PullRequestRow
    var stackPosition: PullRequestStackPosition?
    /// The My PRs group the row is in and why, shown before the repository. Nil hides it.
    var status: MyPullRequestStatus?
    /// The review bot's login from Settings, normalized. Nil hides the bot chip.
    var botReviewer: String?
    // Observe selection here so a row moved between groups on refresh cannot retain a stale snapshot.
    @Binding var selectedPRID: String?
    private var isSelected: Bool { selectedPRID == pr.id }
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
                if let status {
                    // The reason outlasts the repository when the row is narrow: it says why the row is here.
                    Text(status.reason)
                        .fontWeight(.medium)
                        .foregroundStyle(status.group.color)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help("\(status.group.title): \(status.reason)")
                }
                Text("\(pr.repoFullName)#\(String(pr.number))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(pr.repoFullName)#\(String(pr.number))")
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
            if let stackPosition {
                StackChip(position: stackPosition)
            }
            StatusChip(symbolName: "hammer.fill",
                       color: pr.status.tint,
                       help: pr.status.descriptionText)
            if let botReviewer {
                let indicator = pr.reviewStatus.botIndicator(for: botReviewer)
                StatusChip(symbolName: "cpu.fill",
                           color: indicator.color,
                           help: "\(botReviewer): \(indicator.botTitle).")
            }
            StatusChip(symbolName: "person.fill",
                       color: reviewIndicator.color,
                       help: reviewHelp)
        }
        .fixedSize()
    }

    /// The people's reviews. With a review bot set, its review shows on its own chip instead.
    private var humanReviewStatus: PullRequestReviewStatus {
        botReviewer.map(pr.reviewStatus.excludingBot) ?? pr.reviewStatus
    }

    private var reviewIndicator: ReviewIndicator {
        humanReviewStatus.indicator
    }

    private var reviewHelp: String {
        [reviewIndicator.title + ".", humanReviewStatus.helpText].compactMap { $0 }.joined(separator: "\n")
    }

    @ViewBuilder
    private var statusIcon: some View {
        let state = PullRequestState(pr)
        Group {
            if state == .open {
                PullRequestDiscIcon(color: state.tint, diameter: 22)
            } else {
                RowIcon(systemName: state.symbolName, color: state.tint, inCircle: true, diameter: 22)
            }
        }
        .help(state.title)
        .accessibilityLabel(state.title)
    }
}

/// The open state's icon: GitHub's pull request mark, without its arrowhead, white on a colored disc like
/// ``RowIcon``. SF Symbols has no close match for the mark.
struct PullRequestDiscIcon: View {
    let color: Color
    var diameter: CGFloat = 19

    var body: some View {
        PullRequestGlyph(showsArrow: false)
            .stroke(.white, style: StrokeStyle(lineWidth: diameter * 0.068, lineCap: .round, lineJoin: .round))
            .frame(width: diameter * 0.55, height: diameter * 0.55)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(color))
            .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
            .frame(width: max(22, diameter))
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

/// The pull request's place in its stack, such as 2/3, beside the status chips.
struct StackChip: View {
    let position: PullRequestStackPosition

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 9.5, weight: .bold))
            Text(position.label)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Theme.purple.opacity(0.16)))
        .foregroundStyle(Theme.purple)
        .help(position.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(position.helpText)
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

extension MyPullRequestGroup {
    /// The group's heading and its rows' reasons.
    var color: Color {
        switch self {
        case .needsYou: return Theme.red
        case .readyToMerge: return Theme.green
        case .building: return Theme.amber
        case .inReview: return Theme.branch
        case .merging: return Theme.purple
        case .drafts: return .secondary
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

extension ReviewIndicator {
    /// The bot chip's tooltip, after the bot's login.
    var botTitle: String {
        switch self {
        case .none: return "No review requested"
        case .waiting: return "Review requested"
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
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
