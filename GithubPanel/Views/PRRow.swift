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
        HStack(alignment: .top, spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 6) {
                Text(pr.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(pr.title)

                Text("\(pr.repoFullName)#\(String(pr.number)) · \(pr.status.descriptionText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if pr.isDraft {
                        DraftBadge()
                    }

                    Text("Updated \(relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: now))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    mergeButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(PullRequestRowSurface(isSelected: isSelected, isHovering: isHovering))
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var mergeButtonState: MergeButtonState {
        MergeButtonState.resolve(for: pr, isWorking: isMerging)
    }

    private var mergeButton: some View {
        Button(action: handleMergeButtonClick) {
            HStack(spacing: 6) {
                if mergeButtonState == .working {
                    ProgressView()
                        .controlSize(.small)
                        .tint(mergeProgressTint)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: mergeIconName)
                        .font(.caption.weight(.medium))
                        .frame(width: 12)
                }

                Text(mergeButtonTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .foregroundStyle(mergeForeground)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(mergeFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(mergeStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
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

    private var mergeFill: Color {
        switch mergeButtonState {
        case .merge, .enqueue:
            return Color(nsColor: .systemGreen).opacity(isMergeButtonHovering ? 0.85 : 1)
        case .markReady, .enableAutoMerge, .disableAutoMerge:
            return Color.accentColor.opacity(isMergeButtonHovering ? 0.16 : 0.09)
        case .queued:
            return Color.green.opacity(0.09)
        case .checksFailed:
            return Color.red.opacity(0.08)
        case .blocked, .statusUnavailable, .waitingForChecks, .working:
            return Color.primary.opacity(0.04)
        }
    }

    private var mergeForeground: Color {
        switch mergeButtonState {
        case .merge, .enqueue: return Color(nsColor: .labelColor)
        case .markReady, .disableAutoMerge, .enableAutoMerge: return .accentColor
        case .queued: return .green
        case .checksFailed: return .red
        case .blocked, .statusUnavailable, .waitingForChecks, .working: return .secondary
        }
    }

    private var mergeStroke: Color {
        Color.primary.opacity(isMergeButtonHovering ? 0.12 : 0.06)
    }

    private var mergeProgressTint: Color {
        mergeButtonState == .merge || mergeButtonState == .enqueue ? .white : mergeForeground
    }

    private var statusIcon: some View {
        Group {
            switch pr.status {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .noChecks:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            case .failure, .error:
                Image(systemName: "xmark.octagon.fill")
                    .symbolRenderingMode(.multicolor)
            case .pending:
                Image(systemName: "clock.fill")
                    .foregroundStyle(.secondary)
            case .unknown:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 18, weight: .medium))
        .frame(width: 22, height: 22)
    }


}

private struct DraftBadge: View {
    var body: some View {
        Text("DRAFT")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.gray.opacity(0.2))
            )
            .foregroundStyle(.secondary)
    }
}
