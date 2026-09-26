import AppKit
import SwiftUI
import XCTest
@testable import GithubPanel

/// Opening an editor, as the pencil does, should put the cursor in its text field, and ⌘Return should save.
@MainActor
final class PullRequestEditorFocusTests: XCTestCase {
    func testTitleEditorTakesFocusWhenItOpens() throws {
        let responder = try firstResponderAfterOpening {
            PullRequestTitleEditor(title: "Title", onCancel: {}, onSave: { _ in })
        }

        // A focused TextField edits through the window's field editor. The title field is the only text field shown.
        let textView = try XCTUnwrap(responder as? NSTextView)
        XCTAssertTrue(textView.isFieldEditor)
    }

    func testBodyEditorTakesFocusWhenItOpens() throws {
        let responder = try firstResponderAfterOpening {
            PullRequestBodyEditor(body: "Body", onCancel: {}, onSave: { _ in })
        }

        let textView = try XCTUnwrap(responder as? NSTextView)
        XCTAssertFalse(textView.isFieldEditor)
        XCTAssertEqual(textView.string, "Body")
    }

    func testCommandReturnSavesTheTitle() {
        var saved: [String] = []
        withOpenEditor({
            PullRequestTitleEditor(title: "Title", onCancel: {}, onSave: { saved.append($0) })
        }) { window in
            pressCommandReturn(in: window)
        }

        XCTAssertEqual(saved, ["Title"])
    }

    func testCommandReturnSavesTheDescription() {
        var saved: [String] = []
        withOpenEditor({
            PullRequestBodyEditor(body: "Body", onCancel: {}, onSave: { saved.append($0) })
        }) { window in
            pressCommandReturn(in: window)
        }

        XCTAssertEqual(saved, ["Body"])
    }

    private func pressCommandReturn(in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: "\r", charactersIgnoringModifiers: "\r",
                                     isARepeat: false, keyCode: 36)!
        _ = window.performKeyEquivalent(with: event)
        spinRunLoop()
    }

    private func firstResponderAfterOpening<Editor: View>(@ViewBuilder _ editor: @escaping () -> Editor) throws -> NSResponder? {
        var responder: NSResponder?
        withOpenEditor(editor) { window in
            responder = window.firstResponder
        }
        return responder
    }

    /// Shows a button first, like the header, then swaps in the editor and hands over the window while it is open.
    private func withOpenEditor<Editor: View>(@ViewBuilder _ editor: @escaping () -> Editor, _ body: (NSWindow) -> Void) {
        let toggle = EditorToggle()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ToggledEditor(toggle: toggle, editor: editor))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        spinRunLoop()

        toggle.isEditing = true
        spinRunLoop()

        body(window)
    }

    private func spinRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    }
}

private final class EditorToggle: ObservableObject {
    @Published var isEditing = false
}

private struct ToggledEditor<Editor: View>: View {
    @ObservedObject var toggle: EditorToggle
    let editor: () -> Editor

    var body: some View {
        VStack {
            if toggle.isEditing {
                editor()
            } else {
                Button("Edit") { toggle.isEditing = true }
            }
        }
        .padding()
    }
}
