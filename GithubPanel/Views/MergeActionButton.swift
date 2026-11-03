import SwiftUI

/// The merge button over one of your pull requests: what it does, and the method Merge uses.
struct PullRequestMergeAction {
    let state: MergeButtonState
    /// The method the Merge and Enable auto-merge buttons use.
    let mergeMethod: MergeMethod
    let perform: () -> Void
}

/// Merge, Add to queue, Mark ready or auto-merge in the pull request toolbar, sized like its other buttons.
/// When GitHub will not merge yet, it reads as quiet text naming the reason.
struct MergeActionButton: View {
    let action: PullRequestMergeAction

    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: handleClick) {
            HStack(spacing: 6) {
                if state == .working {
                    ProgressView()
                        .controlSize(.small)
                        .tint(progressTint)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: state.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 12)
                }

                Text(state.title(mergeMethod: action.mergeMethod))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(foreground)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(ring, lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
        .disabled(state == .working)
        .opacity(state == .working ? 0.75 : 1)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .onHover { hovering in
            isHovering = hovering && state.hasHoverEffect
        }
    }

    private var state: MergeButtonState {
        action.state
    }

    private func handleClick() {
        guard state.isClickable else { return }
        action.perform()
    }

    private var help: String {
        if state == .enableAutoMerge {
            return "Auto-merge will \(action.mergeMethod.title.lowercased()) once GitHub allows it."
        }
        return state.helpText ?? ""
    }

    /// Only the buttons that do something get a fill. The others read as quiet status text.
    private var fill: Color {
        switch state {
        case .merge, .enqueue:
            return isHovering ? Theme.mergeFill.opacity(0.88) : Theme.mergeFill
        case .markReady, .enableAutoMerge, .disableAutoMerge:
            return Color.accentColor.opacity(isHovering ? 0.22 : 0.15)
        case .queued:
            return Theme.green.opacity(isHovering ? 0.2 : 0.14)
        case .checksFailed:
            return Theme.red.opacity(0.12)
        case .blocked, .statusUnavailable, .waitingForChecks, .working:
            return Color.clear
        }
    }

    /// A hairline around the tinted buttons that keeps them crisp.
    private var ring: Color {
        switch state {
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

    private var foreground: Color {
        switch state {
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

    private var progressTint: Color {
        state == .merge || state == .enqueue ? .white : foreground
    }
}
