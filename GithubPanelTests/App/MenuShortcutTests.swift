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

    /// The menus in the order a Mac app puts them, with no second File-like menu next to File.
    func testMenuBarHasTheExpectedMenus() async throws {
        let titles = try await mainMenu().items.dropFirst().map(\.title)
        XCTAssertEqual(titles, ["File", "Edit", "View", "Pull Request", "Diff", "Window", "Help"])
    }

    /// The list's tabs and Refresh are at the top of View, not in a menu of their own.
    func testViewMenuStartsWithTheListCommands() async throws {
        let titles = try await submenuTitles("View")
        XCTAssertEqual(Array(titles.prefix(5)), ["My PRs", "To Review", "History", "", "Refresh"])
    }

    /// A pull request window needs a pull request, so File must only offer a new main window.
    func testFileMenuOnlyOpensTheMainWindow() async throws {
        let menu = try await mainMenu()
        let file = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let new = try XCTUnwrap(file.items.first)
        XCTAssertEqual(new.title, "New Window")
        XCTAssertEqual(new.keyEquivalent, "n")
        XCTAssertNil(new.submenu)
        XCTAssertFalse(allItems(in: file).contains { $0.title.contains("Pull Request") })
    }

    /// Keyboard Shortcuts is in Help only, not listed again in Window.
    func testKeyboardShortcutsIsOnlyInHelp() async throws {
        let menu = try await mainMenu()
        for top in menu.items {
            let count = allItems(in: top.submenu).filter { $0.title == "Keyboard Shortcuts" }.count
            XCTAssertEqual(count, top.title == "Help" ? 1 : 0, "\(top.title) lists Keyboard Shortcuts \(count) times")
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
        // Only the app's own items, so a system item such as Close All cannot stand in for a dropped shortcut.
        let appTitles = Set(PullRequestTab.allCases.map(\.title) + ["Refresh"])
        let menu = try await mainMenu()
        let view = (menu.item(withTitle: "View")?.submenu?.items ?? []).filter { appTitles.contains($0.title) }
        return view + menu.items
            .filter { ["Pull Request", "Diff", "Help"].contains($0.title) }
            .flatMap { $0.submenu?.items ?? [] }
    }

    private func submenuTitles(_ title: String) async throws -> [String] {
        try await mainMenu().item(withTitle: title)?.submenu?.items.map(\.title) ?? []
    }

    private func mainMenu() async throws -> NSMenu {
        // SwiftUI fills in the app's menus shortly after launch.
        for _ in 0..<20 {
            if let menu = NSApp.mainMenu, menu.item(withTitle: "Help")?.submenu?.item(withTitle: "Keyboard Shortcuts") != nil {
                return menu
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("The app's menus never appeared")
        return NSMenu()
    }

    private func allItems(in menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + allItems(in: $0.submenu) }
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
