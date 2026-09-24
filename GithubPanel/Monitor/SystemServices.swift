import Foundation

protocol DefaultsStoring {
    func double(forKey defaultName: String) -> Double
    func string(forKey defaultName: String) -> String?
    func set(_ value: Double, forKey defaultName: String)
    func set(_ value: String, forKey defaultName: String)
}

extension UserDefaults: DefaultsStoring {
    func set(_ value: String, forKey defaultName: String) {
        set(value as Any, forKey: defaultName)
    }
}

protocol DateProviding {
    var now: Date { get }
}

struct SystemDateProvider: DateProviding {
    var now: Date { Date() }
}

protocol RefreshTimer {
    func invalidate()
}

extension Timer: RefreshTimer {}

protocol TimerScheduling {
    func scheduledTimer(withTimeInterval interval: TimeInterval,
                        repeats: Bool,
                        block: @escaping @MainActor () -> Void) -> RefreshTimer
}

struct SystemTimerScheduler: TimerScheduling {
    func scheduledTimer(withTimeInterval interval: TimeInterval,
                        repeats: Bool,
                        block: @escaping @MainActor () -> Void) -> RefreshTimer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            Task { @MainActor in
                block()
            }
        }
        // Let macOS coalesce this background poll with other wake-ups.
        timer.tolerance = interval * 0.1
        return timer
    }
}
