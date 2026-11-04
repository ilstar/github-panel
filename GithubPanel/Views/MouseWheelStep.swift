import SwiftUI
import AppKit

/// How far one notch of a mouse wheel moves a list or pull request.
///
/// A SwiftUI `ScrollView` keeps AppKit's default line scroll of 10 points, so each notch of a wheel moves a few
/// pixels and the lists feel slow next to other apps. Trackpads and Magic Mice send exact pixel deltas, which do
/// not use the line scroll, so this changes only notched wheels.
enum MouseWheelStep {
    /// Points one wheel notch moves, before macOS speeds up fast spins.
    static let points: CGFloat = 32

    static func apply(to scrollView: NSScrollView) {
        scrollView.verticalLineScroll = points
        scrollView.horizontalLineScroll = points
    }
}

extension View {
    /// Put on a scroll view's content to make each mouse wheel notch move that scroll view by `MouseWheelStep.points`.
    func mouseWheelStep() -> some View {
        background(MouseWheelStepAnchor())
    }
}

/// Sets the line scroll of the scroll view it sits in.
struct MouseWheelStepAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.applyStep()
    }

    final class AnchorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyStep()
        }

        func applyStep() {
            guard window != nil, let scrollView = enclosingScrollView else { return }
            MouseWheelStep.apply(to: scrollView)
        }
    }
}
