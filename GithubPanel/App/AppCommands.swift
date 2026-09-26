import SwiftUI
import AppKit

enum KeyboardShortcutsWindow {
    static let id = "keyboard-shortcuts"
}

/// The menu bar. Every shortcut lives in a menu so it can be found there; see `AppShortcut`.
struct AppCommands: Commands {
    @ObservedObject var monitor: PRMonitor
    @FocusedValue(\.pullRequestList) private var list
    @FocusedValue(\.pullRequestDetail) private var detail
    @FocusedValue(\.pullRequestFiles) private var files
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // The list's tabs and Refresh go at the top of the View menu, like Mail's mailboxes and Safari's Reload.
        CommandGroup(before: .toolbar) {
            ForEach(PullRequestTab.allCases) { tab in
                Button(tab.title) {
                    monitor.selectedTab = tab
                }
                .keyboardShortcut(tab.shortcut)
            }

            Divider()

            Button("Refresh") {
                list?.refresh?()
                detail?.reload()
            }
            .keyboardShortcut(.refresh)
            .disabled(list?.refresh == nil && detail == nil)

            Divider()
        }

        CommandMenu("Pull Request") {
            Button("Open on GitHub") {
                if let url = list?.selection?.htmlURL ?? detail?.htmlURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut(.openOnGitHub)
            .disabled(list?.selection == nil && detail == nil)

            Button("Open in New Window") {
                list?.selection?.openInNewWindow()
            }
            .keyboardShortcut(.openInNewWindow)
            .disabled(list?.selection == nil)

            Divider()

            Button("Copy URL") {
                if let url = list?.selection?.htmlURL ?? detail?.htmlURL {
                    Pasteboard.copy(url.absoluteString)
                }
            }
            .keyboardShortcut(.copyURL)
            .disabled(list?.selection == nil && detail == nil)

            Button("Copy Branch Name") {
                if let branch = detail?.branch {
                    Pasteboard.copy(branch)
                }
            }
            .keyboardShortcut(.copyBranch)
            .disabled(detail == nil)

            Divider()

            let primaryAction = list?.selection?.primaryAction
            Button(primaryAction?.title ?? "Merge") {
                primaryAction?.perform()
            }
            .keyboardShortcut(.primaryAction)
            .disabled(primaryAction?.isEnabled != true)

            Divider()

            Button("Edit Title") {
                detail?.editTitle?()
            }
            .keyboardShortcut(.editTitle)
            .disabled(detail?.editTitle == nil)

            Button("Add Comment") {
                detail?.addComment()
            }
            .keyboardShortcut(.addComment)
            .disabled(detail == nil)

            Divider()

            Button("Show Previous Tab") {
                detail?.showPreviousTab()
            }
            .keyboardShortcut(.previousDetailTab)
            .disabled(detail == nil)

            Button("Show Next Tab") {
                detail?.showNextTab()
            }
            .keyboardShortcut(.nextDetailTab)
            .disabled(detail == nil)
        }

        // Not "Files", which reads as a second File menu.
        CommandMenu("Diff") {
            Button("Filter Files") {
                files?.focusFilter()
            }
            .keyboardShortcut(.filterFiles)
            .disabled(files == nil)

            Button(files?.showsFileTree == false ? "Show File Tree" : "Hide File Tree") {
                files?.toggleFileTree()
            }
            .keyboardShortcut(.toggleFileTree)
            .disabled(files == nil)

            Divider()

            Button("Next File") {
                files?.showNextFile()
            }
            .keyboardShortcut(.nextFile)
            .disabled(files == nil)

            Button("Previous File") {
                files?.showPreviousFile()
            }
            .keyboardShortcut(.previousFile)
            .disabled(files == nil)

            Divider()

            Button("Collapse All") {
                files?.collapseAll?()
            }
            .keyboardShortcut(.collapseAllFiles)
            .disabled(files?.collapseAll == nil)

            Button("Expand All") {
                files?.expandAll?()
            }
            .keyboardShortcut(.expandAllFiles)
            .disabled(files?.expandAll == nil)

            Divider()

            Button(files?.hideWhitespace == true ? "Show Whitespace" : "Hide Whitespace") {
                files?.toggleWhitespace()
            }
            .keyboardShortcut(.toggleWhitespace)
            .disabled(files == nil)

            Button(files?.mode == .split ? "Show Unified Diff" : "Show Split Diff") {
                files?.toggleMode()
            }
            .keyboardShortcut(.toggleDiffMode)
            .disabled(files == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") {
                openWindow(id: KeyboardShortcutsWindow.id)
            }
            .keyboardShortcut(.showShortcuts)
        }
    }
}
