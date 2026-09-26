import SwiftUI

/// Every menu shortcut in the app. The menus and the Keyboard Shortcuts window both read from here, so the
/// keys shown in the window always match the keys that work.
enum AppShortcut: CaseIterable {
    case myPullRequests
    case toReview
    case history
    case refresh

    case openOnGitHub
    case openInNewWindow
    case copyURL
    case copyBranch
    case primaryAction
    case editTitle
    case addComment
    case previousDetailTab
    case nextDetailTab

    case filterFiles
    case toggleFileTree
    case nextFile
    case previousFile
    case collapseAllFiles
    case expandAllFiles
    case toggleWhitespace
    case toggleDiffMode

    case showShortcuts

    var keyboardShortcut: KeyboardShortcut {
        switch self {
        case .myPullRequests: return KeyboardShortcut("1", modifiers: .command)
        case .toReview: return KeyboardShortcut("2", modifiers: .command)
        case .history: return KeyboardShortcut("3", modifiers: .command)
        case .refresh: return KeyboardShortcut("r", modifiers: .command)
        case .openOnGitHub: return KeyboardShortcut("o", modifiers: .command)
        case .openInNewWindow: return KeyboardShortcut("o", modifiers: [.option, .command])
        case .copyURL: return KeyboardShortcut("c", modifiers: [.shift, .command])
        case .copyBranch: return KeyboardShortcut("c", modifiers: [.option, .command])
        case .primaryAction: return KeyboardShortcut("m", modifiers: [.shift, .command])
        case .editTitle: return KeyboardShortcut("e", modifiers: [.option, .command])
        case .addComment: return KeyboardShortcut("n", modifiers: [.option, .command])
        // ⇧⌘[ and ⇧⌘]. Menus match the typed character, and Shift turns [ into {, so the menu needs {.
        case .previousDetailTab: return KeyboardShortcut("{", modifiers: .command)
        case .nextDetailTab: return KeyboardShortcut("}", modifiers: .command)
        case .filterFiles: return KeyboardShortcut("f", modifiers: .command)
        case .toggleFileTree: return KeyboardShortcut("s", modifiers: [.control, .command])
        case .nextFile: return KeyboardShortcut(.downArrow, modifiers: [.option, .command])
        case .previousFile: return KeyboardShortcut(.upArrow, modifiers: [.option, .command])
        case .collapseAllFiles: return KeyboardShortcut(.leftArrow, modifiers: [.option, .command])
        case .expandAllFiles: return KeyboardShortcut(.rightArrow, modifiers: [.option, .command])
        // Not ⌥⌘W, which is the system's Close All.
        case .toggleWhitespace: return KeyboardShortcut("w", modifiers: [.control, .command])
        case .toggleDiffMode: return KeyboardShortcut("u", modifiers: [.option, .command])
        case .showShortcuts: return KeyboardShortcut("/", modifiers: .command)
        }
    }

    /// What the Keyboard Shortcuts window calls it. Menu items whose title changes with state, like the merge
    /// button, use their own title in the menu.
    var title: String {
        switch self {
        case .myPullRequests: return "Show My PRs"
        case .toReview: return "Show To Review"
        case .history: return "Show History"
        case .refresh: return "Refresh the list and the selected pull request"
        case .openOnGitHub: return "Open on GitHub"
        case .openInNewWindow: return "Open in a new window"
        case .copyURL: return "Copy the pull request's URL"
        case .copyBranch: return "Copy the branch name"
        case .primaryAction: return "Merge, mark ready, or toggle auto-merge (same as the row's button)"
        case .editTitle: return "Edit the title"
        case .addComment: return "Write a comment"
        case .previousDetailTab: return "Previous tab (Conversation / Files changed)"
        case .nextDetailTab: return "Next tab (Conversation / Files changed)"
        case .filterFiles: return "Filter files"
        case .toggleFileTree: return "Show or hide the file tree"
        case .nextFile: return "Next file"
        case .previousFile: return "Previous file"
        case .collapseAllFiles: return "Collapse all files"
        case .expandAllFiles: return "Expand all files"
        case .toggleWhitespace: return "Hide or show whitespace changes"
        case .toggleDiffMode: return "Switch between unified and split diff"
        case .showShortcuts: return "Show this list"
        }
    }

    /// The keys as the menu bar draws them, such as "⇧⌘C".
    var symbols: String {
        Self.symbols(for: keyboardShortcut)
    }

    static func symbols(for shortcut: KeyboardShortcut) -> String {
        let shiftedKey = shiftedKeys[shortcut.key.character]
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) || shiftedKey != nil { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        return text + (shiftedKey.map(String.init) ?? keySymbol(shortcut.key))
    }

    /// Characters typed with Shift, drawn as the key pressed.
    private static let shiftedKeys: [Character: Character] = ["{": "[", "}": "]"]

    private static func keySymbol(_ key: KeyEquivalent) -> String {
        switch key {
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .return: return "↩"
        case .space: return "Space"
        default: return String(key.character).uppercased()
        }
    }
}

extension View {
    func keyboardShortcut(_ shortcut: AppShortcut) -> some View {
        keyboardShortcut(shortcut.keyboardShortcut)
    }
}

/// The groups in the Keyboard Shortcuts window: the menu shortcuts plus the single keys that work while no
/// text box is being typed in.
enum ShortcutHelp {
    struct Entry: Hashable {
        let keys: String
        let title: String

        init(_ keys: String, _ title: String) {
            self.keys = keys
            self.title = title
        }

        init(_ shortcut: AppShortcut) {
            self.init(shortcut.symbols, shortcut.title)
        }
    }

    struct Section: Identifiable {
        let title: String
        let entries: [Entry]

        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Pull request list", entries: [
            Entry("↓  or  J", "Next pull request"),
            Entry("↑  or  K", "Previous pull request"),
            Entry("Space", "Scroll the pull request on the right down"),
            Entry("⇧Space", "Scroll the pull request on the right up"),
            Entry("↩", "Open on GitHub"),
            Entry(.myPullRequests),
            Entry(.toReview),
            Entry(.history),
            Entry(.refresh),
        ]),
        Section(title: "Selected pull request", entries: [
            Entry(.openOnGitHub),
            Entry(.openInNewWindow),
            Entry(.copyURL),
            Entry(.copyBranch),
            Entry(.primaryAction),
            Entry(.editTitle),
            Entry(.addComment),
            Entry(.previousDetailTab),
            Entry(.nextDetailTab),
        ]),
        Section(title: "Files changed", entries: [
            Entry(.filterFiles),
            Entry(.toggleFileTree),
            Entry(.nextFile),
            Entry(.previousFile),
            Entry("V", "Mark the current file viewed and go to the next one"),
            Entry(.collapseAllFiles),
            Entry(.expandAllFiles),
            Entry(.toggleWhitespace),
            Entry(.toggleDiffMode),
        ]),
        Section(title: "Help", entries: [
            Entry("\(AppShortcut.showShortcuts.symbols)  or  ?", AppShortcut.showShortcuts.title),
        ]),
    ]

    static let footnote = "Single keys like J, K, V, Space and ? work when you are not typing in a text box. Click a pull request in the list to leave a text box."
}
