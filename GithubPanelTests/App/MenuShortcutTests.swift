import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

@MainActor
final class MenuShortcutTests: XCTestCase {
    /// The menu bar drops a shortcut that another item already uses, without an error. This catches that.
    func testEveryShortcutIsInTheMenuBar() async throws {
        let items = try await menuItems()
        for shortcut in AppShortcut.allCases {
            let key = String(shortcut.keyboardShortcut.key.character)
            let modifiers = Self.flags(shortcut.keyboardShortcut.modifiers)
            let matches = items.filter {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == modifiers
            }
            XCTAssertEqual(matches.count, 1, "\(shortcut.symbols) is in the menu bar \(matches.count) times")
        }
    }

    /// Shift+⌘+[ types {, so the Previous Tab item has to match { for the keys to work.
    func testShiftBracketReachesTheTabItems() {
        for (shortcut, character) in [(AppShortcut.previousDetailTab, "{"), (.nextDetailTab, "}")] {
            let menu = NSMenu()
            let target = Target()
            let item = NSMenuItem(title: shortcut.title, action: #selector(Target.fire(_:)),
                                  keyEquivalent: String(shortcut.keyboardShortcut.key.character))
            item.keyEquivalentModifierMask = Self.flags(shortcut.keyboardShortcut.modifiers)
            item.target = target
            menu.addItem(item)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                         timestamp: 0, windowNumber: 0, context: nil, characters: character,
                                         charactersIgnoringModifiers: character, isARepeat: false,
                                         keyCode: character == "{" ? 33 : 30)!

            XCTAssertTrue(menu.performKeyEquivalent(with: event), shortcut.symbols)
            XCTAssertEqual(target.hits, 1, shortcut.symbols)
        }
    }

    private final class Target: NSObject {
        var hits = 0
        @objc func fire(_ sender: Any?) { hits += 1 }
    }

    private func menuItems() async throws -> [NSMenuItem] {
        // SwiftUI fills in the app's menus shortly after launch.
        for _ in 0..<20 {
            // Only the app's own menus, so a system item such as Close All cannot stand in for a dropped shortcut.
            let items = (NSApp.mainMenu?.items ?? [])
                .filter { ["Pull Requests", "Pull Request", "Files", "Help"].contains($0.title) }
                .flatMap { $0.submenu?.items ?? [] }
            if items.contains(where: { $0.title == "Keyboard Shortcuts" }) { return items }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("The app's menus never appeared")
        return []
    }

    private static func flags(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}
