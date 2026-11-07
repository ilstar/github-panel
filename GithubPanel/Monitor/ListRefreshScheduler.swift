import Foundation

/// Refreshes My PRs and To Review on a timer, in the background. A tick skips a list that loaded within half an
/// interval, such as by a refresh the user asked for, and while GitHub is backing off the sync engine fails it
/// without sending anything, so the next refresh waits for the tick after the backoff ends.
@MainActor
final class ListRefreshScheduler {
    private let timerScheduler: TimerScheduling
    private let interval: @MainActor () -> TimeInterval
    private let refresh: @MainActor (SyncEngine.Priority, _ maxAge: TimeInterval) async -> Void
    private var timer: RefreshTimer?

    init(timerScheduler: TimerScheduling,
         interval: @escaping @MainActor () -> TimeInterval,
         refresh: @escaping @MainActor (SyncEngine.Priority, _ maxAge: TimeInterval) async -> Void) {
        self.timerScheduler = timerScheduler
        self.interval = interval
        self.refresh = refresh
    }

    /// Starts the timer again, such as after the interval changed.
    func schedule() {
        timer?.invalidate()
        timer = timerScheduler.scheduledTimer(withTimeInterval: interval(), repeats: true) { [weak self] in
            Task { await self?.handleTimerTick() }
        }
    }

    func handleTimerTick() async {
        // Ticks run on a fixed cadence that started before the last refresh finished, so a list counts as fresh
        // for half an interval; otherwise the tick due one interval after a refresh would be skipped.
        await refresh(.background, interval() / 2)
    }
}
