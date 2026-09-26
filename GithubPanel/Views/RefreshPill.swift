import SwiftUI

struct RefreshAnimationStopPlan: Equatable {
    let cycle: Double
    let delay: TimeInterval
}

enum RefreshAnimation {
    static let spinDuration: TimeInterval = 1.2

    static func shouldUpdateTimeline(isLoading: Bool, isSettling: Bool) -> Bool {
        isLoading || isSettling
    }

    static func stopPlan(elapsed: TimeInterval) -> RefreshAnimationStopPlan {
        let cycles = max(0, elapsed / spinDuration)
        let stopCycle = ceil(cycles)
        let delay = max(0, (stopCycle * spinDuration) - elapsed)
        return RefreshAnimationStopPlan(cycle: stopCycle, delay: delay)
    }
}

struct RefreshPill: View {
    let isLoading: Bool
    let isEnabled: Bool
    let lastUpdatedView: AnyView
    let action: () -> Void

    @State private var spinStart = Date()
    @State private var stopAtCycle: Double?
    @State private var isSettling = false
    @State private var settleTask: Task<Void, Never>?

    init(isLoading: Bool,
         isEnabled: Bool,
         lastUpdatedView: some View,
         action: @escaping () -> Void) {
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.lastUpdatedView = AnyView(lastUpdatedView)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if RefreshAnimation.shouldUpdateTimeline(isLoading: isLoading, isSettling: isSettling) {
                    TimelineView(.animation) { context in
                        refreshIcon(rotation: rotationAngle(at: context.date))
                    }
                } else {
                    refreshIcon(rotation: 0)
                }
                Text("Refresh")
                    .font(.subheadline.weight(.semibold))
                    .padding(.trailing, 2)
                lastUpdatedView
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onAppear {
            spinStart = Date()
        }
        .onChange(of: isLoading) { loading in
            let now = Date()
            if loading {
                settleTask?.cancel()
                spinStart = now
                stopAtCycle = nil
                isSettling = false
            } else {
                let plan = RefreshAnimation.stopPlan(elapsed: now.timeIntervalSince(spinStart))
                stopAtCycle = plan.cycle
                guard plan.delay > 0 else {
                    finishSettling()
                    return
                }

                isSettling = true
                settleTask = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(plan.delay * 1_000_000_000))
                    } catch {
                        return
                    }
                    finishSettling()
                }
            }
        }
        .onDisappear {
            settleTask?.cancel()
            finishSettling()
        }
    }

    private func rotationAngle(at date: Date) -> Double {
        guard isLoading || stopAtCycle != nil else {
            return 0
        }
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
            .font(.body.weight(.semibold))
            .rotationEffect(.degrees(rotation))
    }

    private func finishSettling() {
        isSettling = false
        stopAtCycle = nil
        settleTask = nil
    }
}
