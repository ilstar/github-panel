import SwiftUI
import AppKit

/// What a double-click on the title bar does, following System Settings →
/// Desktop & Dock → "Double-click a window's title bar to".
enum TitleBarDoubleClickAction: Equatable {
    case zoom
    case minimize
    case none

    static let preferenceKey = "AppleActionOnDoubleClick"

    init(preference: String?) {
        switch preference {
        case "Minimize": self = .minimize
        case "None": self = .none
        // "Maximize" is the default, and "Fill" asks for the same full-size window.
        default: self = .zoom
        }
    }

    static var current: TitleBarDoubleClickAction {
        TitleBarDoubleClickAction(preference: UserDefaults.standard.string(forKey: preferenceKey))
    }

    func perform(on window: NSWindow) {
        switch self {
        case .zoom: window.performZoom(nil)
        case .minimize: window.performMiniaturize(nil)
        case .none: break
        }
    }
}

/// Lets the hidden title bar strip behave like a real one: drag to move and double-click to zoom.
/// Sits behind the window's content, so buttons and text at the top keep their own clicks.
struct TitleBarDoubleClickArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarDoubleClickView {
        TitleBarDoubleClickView()
    }

    func updateNSView(_ nsView: TitleBarDoubleClickView, context: Context) {}
}

final class TitleBarDoubleClickView: NSView {
    /// The height of the title bar strip at the top of the window.
    static func titleBarHeight(of window: NSWindow) -> CGFloat {
        max(0, window.frame.height - window.contentLayoutRect.height)
    }

    /// Whether a point in window coordinates falls in the title bar strip.
    static func isInTitleBar(_ point: NSPoint, windowHeight: CGFloat, titleBarHeight: CGFloat) -> Bool {
        titleBarHeight > 0 && point.y >= windowHeight - titleBarHeight
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window, let superview else { return nil }
        let inWindow = superview.convert(point, to: nil)
        let inContent = window.contentView.map { $0.frame.height } ?? window.frame.height
        guard Self.isInTitleBar(inWindow,
                                windowHeight: inContent,
                                titleBarHeight: Self.titleBarHeight(of: window))
        else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            TitleBarDoubleClickAction.current.perform(on: window)
        } else {
            window.performDrag(with: event)
        }
    }
}
