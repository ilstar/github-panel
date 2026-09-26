import SwiftUI
import AppKit

/// What the main window's list offers the menus. Published with `focusedSceneValue`, so it is only there
/// while the main window is in front.
struct PullRequestListActions {
    /// Nil while the list cannot refresh, for example while it is already loading.
    var refresh: (() -> Void)?
    var selection: SelectedPullRequestActions?
}

struct SelectedPullRequestActions {
    let htmlURL: URL
    let openInNewWindow: () -> Void
    /// The row's merge button. Only pull requests on My PRs have one.
    var primaryAction: PrimaryAction?
}

struct PrimaryAction {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void
}

/// What an open pull request, in the main window or its own window, offers the menus.
struct PullRequestDetailActions {
    let htmlURL: URL
    let branch: String
    let reload: () -> Void
    let showPreviousTab: () -> Void
    let showNextTab: () -> Void
    let addComment: () -> Void
    /// Nil when you cannot edit the pull request.
    let editTitle: (() -> Void)?
}

/// What the Files changed tab offers the menus.
struct PullRequestFilesActions {
    let showsFileTree: Bool
    let hideWhitespace: Bool
    let mode: DiffViewMode
    let focusFilter: () -> Void
    let toggleFileTree: () -> Void
    let showNextFile: () -> Void
    let showPreviousFile: () -> Void
    /// Nil when every file is already collapsed.
    let collapseAll: (() -> Void)?
    /// Nil when every file is already expanded.
    let expandAll: (() -> Void)?
    let toggleWhitespace: () -> Void
    let toggleMode: () -> Void
}

private struct PullRequestListActionsKey: FocusedValueKey {
    typealias Value = PullRequestListActions
}

private struct PullRequestDetailActionsKey: FocusedValueKey {
    typealias Value = PullRequestDetailActions
}

private struct PullRequestFilesActionsKey: FocusedValueKey {
    typealias Value = PullRequestFilesActions
}

extension FocusedValues {
    var pullRequestList: PullRequestListActions? {
        get { self[PullRequestListActionsKey.self] }
        set { self[PullRequestListActionsKey.self] = newValue }
    }

    var pullRequestDetail: PullRequestDetailActions? {
        get { self[PullRequestDetailActionsKey.self] }
        set { self[PullRequestDetailActionsKey.self] = newValue }
    }

    var pullRequestFiles: PullRequestFilesActions? {
        get { self[PullRequestFilesActionsKey.self] }
        set { self[PullRequestFilesActionsKey.self] = newValue }
    }
}

enum Pasteboard {
    static func copy(_ string: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
