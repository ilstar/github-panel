import SwiftUI

struct PRRow: View {
    let pr: PullRequestRow
    let isSelected: Bool
    let relativeFormatter: RelativeDateTimeFormatter
    let now: Date
    let isMerging: Bool
    /// The method the Merge and Enable auto-merge buttons use.
    var mergeMethod: MergeMethod = .merge
    let onAction: () -> Void

    @State private var isHovering = false
    @State private var isMergeButtonHovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                statusIcon
                summary
            }

            Spacer(minLength: 8)

            if mergeButtonState.isShownOnRow {
                mergeButton
            }
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

    private var mergeButtonState: MergeButtonState {
        MergeButtonState.resolve(for: pr, isWorking: isMerging)
    }

    private var mergeButton: some View {
        Button(action: handleMergeButtonClick) {
            HStack(spacing: 5) {
                if mergeButtonState == .working {
                    ProgressView()
                        .controlSize(.small)
                        .tint(mergeProgressTint)
                        .scaleEffect(0.6)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: mergeIconName)
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 11)
                }

                Text(mergeButtonTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 26)
            .foregroundStyle(mergeForeground)
            .background(
                Capsule()
                    .fill(mergeFill)
            )
            .overlay(
                Capsule()
                    .strokeBorder(mergeRing, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(mergeButtonHelp)
        .disabled(mergeButtonState == .working)
        .opacity(mergeButtonState == .working ? 0.75 : 1)
        .animation(.easeInOut(duration: 0.12), value: isMergeButtonHovering)
        .onHover { hovering in
            isMergeButtonHovering = hovering && mergeButtonState.hasHoverEffect
        }
    }

    private func handleMergeButtonClick() {
        guard mergeButtonState.isClickable else { return }
        onAction()
    }

    private var mergeButtonTitle: String {
        mergeButtonState.title(mergeMethod: mergeMethod)
    }

    private var mergeButtonHelp: String {
        if mergeButtonState == .enableAutoMerge {
            return "Auto-merge will \(mergeMethod.title.lowercased()) once GitHub allows it."
        }
        return mergeButtonState.helpText ?? ""
    }

    private var mergeIconName: String {
        mergeButtonState.iconName
    }

    /// Only the buttons that do something get a fill. The others read as quiet status text.
    /// All of them are flat: no sheen or shadow, so the green buttons match the tinted ones.
    private var mergeFill: Color {
        switch mergeButtonState {
        case .merge, .enqueue:
            return isMergeButtonHovering ? Theme.mergeFill.opacity(0.88) : Theme.mergeFill
        case .markReady, .enableAutoMerge, .disableAutoMerge:
            return Color.accentColor.opacity(isMergeButtonHovering ? 0.22 : 0.15)
        case .queued:
            return Theme.green.opacity(isMergeButtonHovering ? 0.2 : 0.14)
        case .checksFailed:
            return Theme.red.opacity(0.12)
        case .blocked, .statusUnavailable, .waitingForChecks, .working:
            return Color.clear
        }
    }

    /// A hairline around the tinted buttons that keeps them crisp on the glass.
    private var mergeRing: Color {
        switch mergeButtonState {
        case .markReady, .enableAutoMerge, .disableAutoMerge:
            return Color.accentColor.opacity(0.3)
        case .queued:
            return Theme.green.opacity(0.3)
        case .checksFailed:
            return Theme.red.opacity(0.28)
        case .merge, .enqueue, .blocked, .statusUnavailable, .waitingForChecks, .working:
            return Color.clear
        }
    }

    private var mergeForeground: Color {
        switch mergeButtonState {
        case .merge, .enqueue:
            return Color.white
        case .markReady, .disableAutoMerge, .enableAutoMerge:
            return Color.accentColor
        case .queued:
            return Theme.green
        case .checksFailed:
            return Theme.red
        case .blocked, .statusUnavailable, .waitingForChecks, .working:
            return Color.secondary
        }
    }

    private var mergeProgressTint: Color {
        mergeButtonState == .merge || mergeButtonState == .enqueue ? .white : mergeForeground
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
