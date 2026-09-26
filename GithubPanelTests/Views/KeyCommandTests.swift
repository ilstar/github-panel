import XCTest
import AppKit
@testable import GithubPanel

@MainActor
final class KeyCommandTests: XCTestCase {
    private func command(_ keyCode: UInt16, _ characters: String?, _ modifiers: NSEvent.ModifierFlags = []) -> KeyCommand? {
        KeyCommand.command(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    func testArrowsAndVimKeysMoveTheSelection() {
        // Arrow keys carry the function and numeric pad flags.
        XCTAssertEqual(command(125, nil, [.function, .numericPad]), .nextItem)
        XCTAssertEqual(command(126, nil, [.function, .numericPad]), .previousItem)
        XCTAssertEqual(command(38, "j"), .nextItem)
        XCTAssertEqual(command(40, "k"), .previousItem)
    }

    func testReturnOpensAndSpacePages() {
        XCTAssertEqual(command(36, "\r"), .open)
        XCTAssertEqual(command(76, "\u{3}"), .open)
        XCTAssertEqual(command(49, " "), .pageDown)
        XCTAssertEqual(command(49, " ", .shift), .pageUp)
    }

    func testViewedAndHelpKeys() {
        XCTAssertEqual(command(9, "v"), .toggleViewed)
        XCTAssertEqual(command(44, "?", .shift), .showShortcuts)
    }

    func testKeysWithCommandControlOrOptionPassThrough() {
        XCTAssertNil(command(38, "j", .command))
        XCTAssertNil(command(125, nil, [.function, .option]))
        XCTAssertNil(command(49, " ", .control))
        XCTAssertNil(command(36, "\r", .command))
    }

    func testOtherKeysPassThrough() {
        XCTAssertNil(command(0, "a"))
        XCTAssertNil(command(38, "J", .shift))
        XCTAssertNil(command(125, nil, [.function, .shift]))
    }

    func testTypingOnlyCountsInAnEditableTextView() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(textView)

        XCTAssertFalse(KeyCommand.isTyping(in: window))
        XCTAssertFalse(KeyCommand.isTyping(in: nil))

        window.makeFirstResponder(textView)
        XCTAssertTrue(KeyCommand.isTyping(in: window))

        textView.isEditable = false
        XCTAssertFalse(KeyCommand.isTyping(in: window))

        textView.isEditable = true
        window.endTyping()
        XCTAssertFalse(KeyCommand.isTyping(in: window))
    }
}
