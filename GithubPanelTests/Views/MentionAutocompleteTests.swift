import AppKit
import SwiftUI
import XCTest
@testable import GithubPanel

/// Typing "@" in a comment box opens the mention menu under the cursor; Return mentions the chosen user.
@MainActor
final class MentionAutocompleteTests: XCTestCase {
    private var window: NSWindow!
    private var searches: [String] = []

    override func setUp() {
        super.setUp()
        searches = []
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 500, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MentionHost(search: { [unowned self] query in
            searches.append(query)
            let users = [MentionCandidate(login: "monalisa", name: "Mona Lisa"), MentionCandidate(login: "mojombo", name: "Tom")]
            return users.filter { query.isEmpty || $0.login.hasPrefix(query) }
        }))
        window.makeKeyAndOrderFront(nil)
        spinRunLoop()
    }

    override func tearDown() {
        window.orderOut(nil)
        window.contentView = nil
        window = nil
        super.tearDown()
    }

    func testTypingAMentionShowsMatchesAndReturnInsertsTheLogin() throws {
        let textView = try focusedTextView()

        textView.insertText("Thanks @mo", replacementRange: textView.selectedRange())
        spinRunLoop()

        let panel = try XCTUnwrap(mentionPanel())
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.logins, ["monalisa", "mojombo"])
        XCTAssertEqual(searches.last, "mo")

        let controller = try XCTUnwrap(panel.controller)
        XCTAssertTrue(controller.handle(keyCode: 125, modifiers: [])) // down arrow
        XCTAssertTrue(controller.handle(keyCode: 36, modifiers: [])) // return
        spinRunLoop()

        XCTAssertEqual(textView.string, "Thanks @mojombo ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 16, length: 0))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(controller.handle(keyCode: 36, modifiers: []), "Return types a newline once the menu is closed")
    }

    func testEscapeClosesTheMenuUntilTheNextMention() throws {
        let textView = try focusedTextView()
        textView.insertText("@", replacementRange: textView.selectedRange())
        spinRunLoop()
        let panel = try XCTUnwrap(mentionPanel())
        let controller = try XCTUnwrap(panel.controller)
        XCTAssertEqual(searches, [""])

        XCTAssertTrue(controller.handle(keyCode: 53, modifiers: [])) // escape
        textView.insertText("m", replacementRange: textView.selectedRange())
        spinRunLoop()
        XCTAssertFalse(panel.isVisible)

        textView.insertText(" @", replacementRange: textView.selectedRange())
        spinRunLoop()
        XCTAssertTrue(panel.isVisible)
    }

    func testAnEmailDoesNotOpenTheMenu() throws {
        let textView = try focusedTextView()
        textView.insertText("me@mo", replacementRange: textView.selectedRange())
        spinRunLoop()

        XCTAssertTrue(searches.isEmpty)
        XCTAssertFalse(mentionPanel()?.isVisible ?? false)
    }

    private func focusedTextView() throws -> NSTextView {
        let textView = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(textView.isFieldEditor)
        return textView
    }

    private func mentionPanel() -> MentionPanel? {
        window.childWindows?.compactMap { $0 as? MentionPanel }.first
    }

    private func spinRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
    }
}

private struct MentionHost: View {
    let search: MentionSearch
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .mentionAutocomplete()
            .focused($isFocused)
            .frame(width: 300, height: 120)
            .padding()
            .environment(\.mentionSearch, search)
            .onAppear { DispatchQueue.main.async { isFocused = true } }
    }
}
