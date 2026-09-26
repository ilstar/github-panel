import SwiftUI
import AppKit

/// The single keys that work while nothing is being typed: J, K, Space, V and so on.
enum KeyCommand: Equatable {
    case nextItem
    case previousItem
    case open
    case pageDown
    case pageUp
    case toggleViewed
    case showShortcuts

    /// The command for a key press, or nil to let the key through. Keys held with ⌘, ⌃ or ⌥ always go through,
    /// so menu shortcuts and text editing keep working.
    static func command(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> KeyCommand? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }
        let shift = modifiers.contains(.shift)

        switch keyCode {
        case 125: return shift ? nil : .nextItem // down arrow
        case 126: return shift ? nil : .previousItem // up arrow
        case 36, 76: return shift ? nil : .open // return, enter
        case 49: return shift ? .pageUp : .pageDown // space
        default: break
        }

        switch characters {
        case "j": return .nextItem
        case "k": return .previousItem
        case "v": return .toggleViewed
        case "?": return .showShortcuts
        default: return nil
        }
    }

    /// True while the window's focus is in a text box, where every key is typing.
    static func isTyping(in window: NSWindow?) -> Bool {
        guard let textView = window?.firstResponder as? NSTextView else { return false }
        return textView.isEditable
    }
}

/// Watches key presses in its window and hands the `KeyCommand`s to `handler`. Return true from the handler
/// to use up the key. Keys pass through while a text box has focus.
///
/// A monitor instead of a first-responder view, so the keys keep working after a click on a row or a diff,
/// which do not take keyboard focus.
struct KeyCommandMonitor: NSViewRepresentable {
    var handler: (KeyCommand) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.handler = handler
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var view: NSView?
        var handler: ((KeyCommand) -> Bool)?
        private var monitor: Any?

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window, event.window === window,
                      !KeyCommand.isTyping(in: window),
                      let command = KeyCommand.command(keyCode: event.keyCode,
                                                       characters: event.charactersIgnoringModifiers,
                                                       modifiers: event.modifierFlags),
                      self.handler?(command) == true
                else { return event }
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

extension NSWindow {
    /// Takes focus out of any text box, so the single-key commands work again.
    func endTyping() {
        if KeyCommand.isTyping(in: self) {
            makeFirstResponder(nil)
        }
    }
}
