import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// ⌃⌥⌘G by default, so it works before anyone visits Settings. Change or clear it in Settings.
    static let toggleApp = Self("toggleApp", default: .init(.g, modifiers: [.control, .option, .command]))
}
