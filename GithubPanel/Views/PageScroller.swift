import SwiftUI
import AppKit

/// Scrolls the pull request on the right by a page while the keyboard stays on the list, like Space in Mail.
/// The scroll view registers itself by placing a `PageScrollAnchor` in its content.
@MainActor
final class PageScroller {
    /// How much of the old page stays on screen after a page, so the reader keeps their place.
    static let overlap: CGFloat = 40

    weak var scrollView: NSScrollView?

    func page(down: Bool) {
        guard let scrollView else { return }
        Self.page(scrollView, down: down)
    }

    static func page(_ scrollView: NSScrollView, down: Bool) {
        guard let document = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let visible = clipView.bounds
        let step = max(visible.height - overlap, overlap)
        // In a flipped document y grows downward, so a page down adds to it.
        let delta = document.isFlipped == down ? step : -step
        let maxY = max(document.frame.height - visible.height, 0)
        let y = min(max(visible.origin.y + delta, 0), maxY)
        clipView.scroll(to: NSPoint(x: visible.origin.x, y: y))
        scrollView.reflectScrolledClipView(clipView)
    }
}

private struct PageScrollerKey: EnvironmentKey {
    static let defaultValue: PageScroller? = nil
}

extension EnvironmentValues {
    var pageScroller: PageScroller? {
        get { self[PageScrollerKey.self] }
        set { self[PageScrollerKey.self] = newValue }
    }
}

/// Put in a scroll view's content to make that scroll view the one Space pages. The latest one shown wins.
struct PageScrollAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.scroller = context.environment.pageScroller
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.scroller = context.environment.pageScroller
        nsView.register()
    }

    final class AnchorView: NSView {
        weak var scroller: PageScroller?
        private weak var registered: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if let registered, scroller?.scrollView === registered {
                    scroller?.scrollView = nil
                }
                registered = nil
            } else {
                register()
            }
        }

        func register() {
            guard window != nil, let scrollView = enclosingScrollView, let scroller else { return }
            if registered !== scrollView || scroller.scrollView == nil {
                scroller.scrollView = scrollView
                registered = scrollView
            }
        }
    }
}
