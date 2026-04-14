import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleApp = Self("toggleApp")
    static let refreshPullRequests = Self("refreshPullRequests", default: .init(.r, modifiers: [.command]))
}
