import AppKit
import SwiftUI

/// Attached only to the test host's main scene. Other windows remain available
/// for tests that explicitly exercise them.
struct TestHostWindowHidingView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowHidingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowHidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // SwiftUI can order the window front after attaching its content.
            // Make it transparent first so it never flashes on screen, then
            // remove it once SwiftUI has finished the current layout pass.
            window.alphaValue = 0
            DispatchQueue.main.async { [weak window] in
                window?.orderOut(nil)
            }
        }
    }
}
