import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

final class AppShortcutTests: XCTestCase {
    func testNoTwoMenuShortcutsShareKeys() {
        let keys = AppShortcut.allCases.map { "\($0.keyboardShortcut.modifiers.rawValue)-\($0.keyboardShortcut.key.character)" }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testMenuShortcutsLeaveStandardMacKeysAlone() {
        let command = ["q", "w", "h", "m", "c", "v", "x", "z", "a", ","].map { KeyboardShortcut(KeyEquivalent(Character($0)), modifiers: .command) }
        // Close All, Hide Others, Dock hiding, full screen, Lock Screen and Emoji & Symbols.
        let system = [KeyboardShortcut("w", modifiers: [.option, .command]),
                      KeyboardShortcut("h", modifiers: [.option, .command]),
                      KeyboardShortcut("d", modifiers: [.option, .command]),
                      KeyboardShortcut("f", modifiers: [.control, .command]),
                      KeyboardShortcut("q", modifiers: [.control, .command]),
                      KeyboardShortcut(.space, modifiers: [.control, .command])]
        for shortcut in AppShortcut.allCases.map(\.keyboardShortcut) {
            XCTAssertFalse((command + system).contains(shortcut), AppShortcut.symbols(for: shortcut))
        }
    }

    func testSymbolsFollowTheMenuBarOrder() {
        XCTAssertEqual(AppShortcut.myPullRequests.symbols, "⌘1")
        XCTAssertEqual(AppShortcut.copyURL.symbols, "⇧⌘C")
        XCTAssertEqual(AppShortcut.copyBranch.symbols, "⌥⌘C")
        XCTAssertEqual(AppShortcut.toggleFileTree.symbols, "⌃⌘S")
        XCTAssertEqual(AppShortcut.nextFile.symbols, "⌥⌘↓")
        XCTAssertEqual(AppShortcut.collapseAllFiles.symbols, "⌥⌘←")
        XCTAssertEqual(AppShortcut.previousDetailTab.symbols, "⇧⌘[")
        XCTAssertEqual(AppShortcut.nextDetailTab.symbols, "⇧⌘]")
        XCTAssertEqual(AppShortcut.toggleWhitespace.symbols, "⌃⌘W")
        XCTAssertEqual(AppShortcut.showShortcuts.symbols, "⌘/")
    }

    func testShortcutsWindowListsEveryMenuShortcut() {
        let listed = ShortcutHelp.sections.flatMap(\.entries).map(\.keys).joined(separator: " ")
        for shortcut in AppShortcut.allCases {
            XCTAssertTrue(listed.contains(shortcut.symbols), shortcut.symbols)
        }
    }

    func testShortcutsWindowListsTheSingleKeys() {
        let listed = ShortcutHelp.sections.flatMap(\.entries).map(\.keys).joined(separator: " ")
        for key in ["J", "K", "Space", "⇧Space", "↩", "V", "?"] {
            XCTAssertTrue(listed.contains(key), key)
        }
        XCTAssertEqual(ShortcutHelp.sections.count, 4)
    }

    func testPullRequestTabsUseCommandNumbers() {
        XCTAssertEqual(PullRequestTab.allCases.map(\.shortcut.symbols), ["⌘1", "⌘2", "⌘3"])
    }

    func testPasteboardCopyReplacesTheContents() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AppShortcutTests-\(UUID().uuidString)"))
        pasteboard.setString("old", forType: .string)

        Pasteboard.copy("feature/branch", to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "feature/branch")
        pasteboard.releaseGlobally()
    }
}
