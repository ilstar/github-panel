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
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
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
                }
            }

            Spacer(minLength: 0)

            mergeButton
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.04), radius: 8, x: 0, y: 2)
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
                        .font(.caption.weight(.bold))
                        .frame(width: 12)
                }

                Text(mergeButtonTitle)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            .frame(width: 168, height: 30)
            .foregroundStyle(mergeForeground)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(mergeFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(mergeStroke, lineWidth: 1)
            )
            .shadow(color: mergeShadow, radius: isMerging ? 0 : 4, x: 0, y: 1)
            .offset(y: mergeButtonOffset)
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
        case .markReady, .enableAutoMerge, .disableAutoMerge:
            return isMergeButtonHovering
                ? Color(red: 0.91, green: 0.96, blue: 1.0)
                : Color(red: 0.95, green: 0.98, blue: 1.0)
        case .merge, .enqueue:
            return isMergeButtonHovering
                ? Color(red: 0.16, green: 0.56, blue: 0.29)
                : Color(red: 0.13, green: 0.49, blue: 0.25)
        case .queued:
            return isMergeButtonHovering
                ? Color(red: 0.94, green: 0.99, blue: 0.96)
                : Color.white
        case .checksFailed:
            return Color(red: 1.0, green: 0.96, blue: 0.96)
        case .blocked, .statusUnavailable, .waitingForChecks, .working:
            return Color.white
        }
    }

    private var mergeForeground: Color {
        switch mergeButtonState {
        case .merge, .enqueue:
            return Color.white
        case .markReady, .disableAutoMerge, .enableAutoMerge:
            return Color(red: 0.14, green: 0.36, blue: 0.62)
        case .queued:
            return Color(red: 0.10, green: 0.43, blue: 0.24)
        case .checksFailed:
            return Color(red: 0.72, green: 0.16, blue: 0.16)
        case .blocked, .statusUnavailable, .waitingForChecks, .working:
            return Color.secondary
        }
    }

    private var mergeStroke: Color {
        switch mergeButtonState {
        case .markReady, .disableAutoMerge, .enableAutoMerge:
            return Color(red: 0.50, green: 0.68, blue: 0.86).opacity(isMergeButtonHovering ? 0.68 : 0.45)
        case .merge, .enqueue:
            return Color(red: 0.06, green: 0.38, blue: 0.16).opacity(isMergeButtonHovering ? 0.62 : 0.45)
        case .queued:
            return Color(red: 0.30, green: 0.63, blue: 0.42).opacity(isMergeButtonHovering ? 0.55 : 0.32)
        case .checksFailed:
            return Color(red: 0.78, green: 0.22, blue: 0.20).opacity(0.34)
        case .blocked, .statusUnavailable, .waitingForChecks, .working:
            return Color.black.opacity(0.12)
        }
    }

    private var mergeShadow: Color {
        switch mergeButtonState {
        case .markReady, .disableAutoMerge, .enableAutoMerge:
            return Color.black.opacity(isMergeButtonHovering ? 0.10 : 0.06)
        case .merge, .enqueue:
            return Color.green.opacity(isMergeButtonHovering ? 0.26 : 0.18)
        case .queued:
            return Color.green.opacity(isMergeButtonHovering ? 0.14 : 0.07)
        case .blocked, .statusUnavailable, .checksFailed, .waitingForChecks, .working:
            return Color.black.opacity(0.04)
        }
    }

    private var mergeProgressTint: Color {
        mergeButtonState == .merge || mergeButtonState == .enqueue ? .white : mergeForeground
    }

    private var mergeButtonOffset: CGFloat {
        isMergeButtonHovering ? -1 : 0
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
        .font(.title)
        .frame(width: 30)
    }

    private var cardFill: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(
                LinearGradient(colors: [
                    Color(red: 0.93, green: 0.96, blue: 1.0),
                    Color(red: 0.98, green: 0.99, blue: 1.0)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        return AnyShapeStyle(Color.white.opacity(isHovering ? 0.95 : 0.9))
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
