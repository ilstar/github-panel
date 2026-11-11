import SwiftUI

struct RefreshAnimationStopPlan: Equatable {
    let cycle: Double
    let delay: TimeInterval
}

enum RefreshAnimation {
    static let spinDuration: TimeInterval = 1.6
    /// How long the pill takes to widen for the progress text, and to narrow back after.
    static let resizeDuration: TimeInterval = 0.3

    static func stopPlan(elapsed: TimeInterval) -> RefreshAnimationStopPlan {
        let cycles = max(0, elapsed / spinDuration)
        let stopCycle = ceil(cycles)
        let delay = max(0, (stopCycle * spinDuration) - elapsed)
        return RefreshAnimationStopPlan(cycle: stopCycle, delay: delay)
    }
}

/// The steps the refresh pill goes through: it widens for the progress text, then spins its icon until the refresh
/// is done, lets the icon finish its turn, and narrows back to when the list last updated.
enum RefreshPillPhase: Equatable {
    /// Narrow, showing when the list last updated.
    case idle
    /// Widening for the progress text. The icon waits until it is wide.
    case expanding
    /// Spinning while the refresh runs.
    case spinning
    /// The refresh is done and the icon is finishing its turn. It narrows once the icon stops.
    case stopping

    var isExpanded: Bool { self != .idle }
    var isSpinning: Bool { self == .spinning || self == .stopping }

    /// A refresh starting widens a narrow pill, and keeps spinning an icon that was stopping.
    func refreshStarted() -> RefreshPillPhase {
        switch self {
        case .idle: return .expanding
        case .stopping: return .spinning
        case .expanding, .spinning: return self
        }
    }

    /// A refresh ending lets a spinning icon finish its turn. One that ends while the pill widens waits for it.
    func refreshEnded() -> RefreshPillPhase {
        self == .spinning ? .stopping : self
    }

    /// Once the pill is wide, the icon spins if the refresh is still running; otherwise the pill narrows back.
    func expanded(isRefreshing: Bool) -> RefreshPillPhase {
        guard self == .expanding else { return self }
        return isRefreshing ? .spinning : .idle
    }
}

struct RefreshPill: View {
    let isRefreshing: Bool
    /// What the refresh is doing, such as "Refreshing My PRs 2/10…". Nil when it isn't refreshing.
    let progressText: String?
    /// Shown while not refreshing, such as "Updated 1 min. ago".
    let updatedText: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var phase: RefreshPillPhase = .idle
    /// `isRefreshing` as last seen. The phase steps run later and read this, since `isRefreshing` is a copy.
    @State private var refreshing = false
    /// The progress text stays up after the refresh ends, while the icon finishes its turn.
    @State private var shownProgressText = Self.startingText
    @State private var spinStart = Date()
    @State private var stopAtCycle: Double?
    @State private var nextStep: Task<Void, Never>?
    @State private var isHovering = false

    private static let startingText = "Refreshing…"

    private var label: String {
        phase.isExpanded ? (progressText ?? shownProgressText) : updatedText
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.tertiary)
                    // A new view for each text, so a change cross-fades while the pill resizes instead of clipping.
                    .id(label)
                    .transition(.opacity)
                Group {
                    if phase.isSpinning {
                        TimelineView(.animation) { context in
                            refreshIcon(rotation: rotationAngle(at: context.date))
                        }
                    } else {
                        refreshIcon(rotation: 0)
                    }
                }
                .foregroundStyle(isHovering && isEnabled ? Color.primary : Color.secondary)
            }
            .padding(.leading, 12)
            .padding(.trailing, 9)
            .frame(height: 34)
            .controlChrome(in: Capsule())
            .brightness(isHovering && isEnabled ? 0.03 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabledIfAvailable()
        .disabled(!isEnabled)
        .help("Refresh")
        .accessibilityLabel("Refresh")
        .accessibilityValue(label)
        // Progress counts change while the pill is wide. The "Updated" time ticking over doesn't animate.
        .animation(.easeInOut(duration: 0.2), value: phase.isExpanded ? label : nil)
        .onHover { isHovering = $0 }
        .onAppear {
            guard isRefreshing else { return }
            refreshing = true
            refreshStarted()
        }
        .onChange(of: isRefreshing) { isRefreshing in
            refreshing = isRefreshing
            if isRefreshing {
                refreshStarted()
            } else {
                refreshEnded()
            }
        }
        .onChange(of: progressText) { text in
            if let text { shownProgressText = text }
        }
        .onDisappear {
            nextStep?.cancel()
            nextStep = nil
            stopAtCycle = nil
            phase = .idle
        }
    }

    /// Widens the pill, then spins the icon once it is wide.
    private func refreshStarted() {
        switch phase.refreshStarted() {
        case .expanding:
            shownProgressText = progressText ?? Self.startingText
            withAnimation(.easeInOut(duration: RefreshAnimation.resizeDuration)) { phase = .expanding }
            run(after: RefreshAnimation.resizeDuration) {
                if phase.expanded(isRefreshing: refreshing) == .spinning {
                    spinStart = Date()
                    phase = .spinning
                } else {
                    collapse()
                }
            }
        case .spinning where phase == .stopping:
            // Keeps turning from where the icon is, without restarting the turn.
            nextStep?.cancel()
            stopAtCycle = nil
            phase = .spinning
        default:
            break
        }
    }

    /// Lets the icon finish its turn, then narrows the pill.
    private func refreshEnded() {
        guard phase.refreshEnded() == .stopping, phase == .spinning else { return }
        let plan = RefreshAnimation.stopPlan(elapsed: Date().timeIntervalSince(spinStart))
        stopAtCycle = plan.cycle
        phase = .stopping
        run(after: plan.delay) { collapse() }
    }

    private func collapse() {
        stopAtCycle = nil
        withAnimation(.easeInOut(duration: RefreshAnimation.resizeDuration)) { phase = .idle }
    }

    /// Runs the next step after `delay`, replacing any step still waiting.
    private func run(after delay: TimeInterval, _ step: @escaping @MainActor () -> Void) {
        nextStep?.cancel()
        nextStep = Task { @MainActor in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            nextStep = nil
            step()
        }
    }

    private func rotationAngle(at date: Date) -> Double {
        guard phase.isSpinning else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(spinStart))
        let cycles = elapsed / RefreshAnimation.spinDuration
        if let stopAtCycle, cycles >= stopAtCycle {
            return 0
        }
        let fraction = cycles.truncatingRemainder(dividingBy: 1)
        return fraction * 360
    }

    private func refreshIcon(rotation: Double) -> some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 13, weight: .semibold))
            .rotationEffect(.degrees(rotation))
    }
}
