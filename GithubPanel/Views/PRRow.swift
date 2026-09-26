import SwiftUI

struct PRRow: View {
    let pr: PullRequestRow
    let isSelected: Bool
    let relativeFormatter: RelativeDateTimeFormatter
    let now: Date
    let isMerging: Bool
    let onAction: () -> Void

    @State private var isHovering = false
    @State private var isMergeButtonHovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statusIcon
                summary
            }

            Spacer(minLength: 8)

            mergeButton
        }
        .listRowBackground(isSelected: isSelected, isHovering: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pr.title)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(1)
                .help(pr.title)

            HStack(spacing: 6) {
                if pr.isDraft {
                    TagView(text: "DRAFT")
                }

                Text("\(pr.repoFullName)#\(String(pr.number)) · \(pr.status.descriptionText)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("Updated \(relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: now))")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .font(.caption)
        }
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
            .padding(.horizontal, 11)
            .frame(height: 24)
            .foregroundStyle(mergeForeground)
            .background(
                Capsule()
                    .fill(mergeFill)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
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
        mergeButtonState.title
    }

    private var mergeIconName: String {
        mergeButtonState.iconName
    }

    /// Only the buttons that do something get a fill. The others read as quiet status text.
    private var mergeFill: Color {
        switch mergeButtonState {
        case .merge, .enqueue:
            return isMergeButtonHovering ? Theme.green.opacity(0.85) : Theme.green
        case .markReady, .enableAutoMerge, .disableAutoMerge:
            return Color.accentColor.opacity(isMergeButtonHovering ? 0.2 : 0.12)
        case .queued:
            return Theme.green.opacity(isMergeButtonHovering ? 0.18 : 0.1)
        case .checksFailed:
            return Theme.red.opacity(0.1)
        case .blocked, .statusUnavailable, .waitingForChecks, .working:
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
        Group {
            switch pr.status {
            case .success:
                RowIcon(systemName: "checkmark.circle.fill", color: Theme.green)
            case .noChecks:
                RowIcon(systemName: "minus.circle.fill", color: .secondary)
            case .failure, .error:
                RowIcon(systemName: "xmark.circle.fill", color: Theme.red)
            case .pending:
                RowIcon(systemName: "clock.circle.fill", color: Theme.amber)
            case .unknown:
                RowIcon(systemName: "questionmark.circle.fill", color: .secondary)
            }
        }
    }
}
