import SwiftUI
import AppKit

/// Remembers when a scroll view last moved, so its rows can ignore the pointer while the list scrolls.
///
/// Rows slide under a still pointer as the list scrolls. SwiftUI checks hover again after every update, so a row
/// that changes when hovered makes one more update, which moves the rows again and hovers the next one. On a long
/// diff each of those updates re-measures the whole list, and the app can stop responding.
@MainActor
final class ScrollActivity {
    /// How long after the last movement the list still counts as scrolling. Long enough to cover the gaps between
    /// momentum frames.
    static let settleInterval: TimeInterval = 0.25

    private var lastMovement: TimeInterval = -.infinity

    func noteMovement(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastMovement = time
    }

    func isScrolling(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        time - lastMovement < Self.settleInterval
    }
}

/// Put in a scroll view's content to record each time that scroll view moves in `activity`.
struct ScrollActivityMonitor: NSViewRepresentable {
    let activity: ScrollActivity

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.activity = activity
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.activity = activity
    }

    final class MonitorView: NSView {
        var activity: ScrollActivity?
        private weak var observedClipView: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil, let clipView = enclosingScrollView?.contentView else { return }
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsDidChange),
                                                   name: NSView.boundsDidChangeNotification, object: clipView)
            observedClipView = clipView
        }

        @objc private func clipViewBoundsDidChange(_ notification: Notification) {
            activity?.noteMovement()
        }

        private func stopObserving() {
            guard let observedClipView else { return }
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                      object: observedClipView)
            self.observedClipView = nil
        }
    }
}
