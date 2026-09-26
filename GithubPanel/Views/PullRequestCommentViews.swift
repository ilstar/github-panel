import SwiftUI
import AppKit

/// One comment: who wrote it, when, and its Markdown body.
struct PullRequestCommentView: View {
    let comment: PullRequestComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.authorLogin)
                    .font(.callout.weight(.semibold))
                Text("commented \(comment.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                Spacer(minLength: 8)
                if let url = comment.htmlURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open comment on GitHub")
                }
            }
            MarkdownView(markdown: comment.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A text box for writing a comment. Keeps the draft and shows GitHub's error when posting fails.
struct CommentComposer: View {
    let placeholder: String
    let submitTitle: String
    /// Shows a Cancel button and handles Escape. Nil for the always-visible composer on the Conversation tab.
    var onCancel: (() -> Void)?
    /// Posts the trimmed text. Throws to keep the draft and show the error.
    let onSubmit: (String) async throws -> Void

    @State private var text = ""
    @State private var isPosting = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .frame(minHeight: 64, maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                    .onExitCommand { onCancel?() }
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            )

            HStack(spacing: 8) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                Spacer(minLength: 8)
                if isPosting {
                    ProgressView().controlSize(.small)
                }
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .disabled(isPosting)
                }
                submitButton
            }
        }
        .onAppear {
            // An inline composer opens from a click on a line, so start typing right away.
            if onCancel != nil { isFocused = true }
        }
    }

    @ViewBuilder
    private var submitButton: some View {
        let button = Button(submitTitle, action: submit)
            .buttonStyle(.borderedProminent)
            .disabled(Self.trimmed(text).isEmpty || isPosting)
            .help("\(submitTitle) (⌘Return)")
        // Only the focused composer answers ⌘Return, since several can be open at once.
        if isFocused {
            button.keyboardShortcut(.return, modifiers: .command)
        } else {
            button
        }
    }

    private func submit() {
        let body = Self.trimmed(text)
        guard !body.isEmpty, !isPosting else { return }
        isPosting = true
        errorMessage = nil
        Task {
            do {
                try await onSubmit(body)
                text = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isPosting = false
        }
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A review thread on the diff: its comments and a reply box. Resolved threads start folded, like on GitHub.
struct ReviewThreadView: View {
    let thread: ReviewThread
    let onReply: (String) async throws -> Void

    @State private var isExpanded: Bool
    @State private var isReplying = false

    init(thread: ReviewThread, onReply: @escaping (String) async throws -> Void) {
        self.thread = thread
        self.onReply = onReply
        _isExpanded = State(initialValue: !thread.isResolved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                ForEach(thread.comments) { comment in
                    Divider()
                    PullRequestCommentView(comment: comment)
                        .padding(12)
                }
                Divider()
                Group {
                    if isReplying {
                        CommentComposer(placeholder: "Reply…",
                                        submitTitle: "Reply",
                                        onCancel: { isReplying = false },
                                        onSubmit: { body in
                                            try await onReply(body)
                                            isReplying = false
                                        })
                    } else {
                        Button {
                            isReplying = true
                        } label: {
                            Text("Reply…")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
        }
        .font(.body)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .frame(width: 10)
                Text(Self.title(thread))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                if thread.isOutdated {
                    ThreadBadge(text: "Outdated")
                }
                if thread.isResolved {
                    ThreadBadge(text: "Resolved")
                }
                Spacer(minLength: 8)
                if !isExpanded {
                    Text(Self.summary(thread))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.06))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse conversation" : "Expand conversation")
    }

    /// Names the commented lines, such as `Widget.swift line 12` or `lines 10–12`.
    static func title(_ thread: ReviewThread) -> String {
        let name = (thread.path as NSString).lastPathComponent
        guard let line = thread.line else { return name }
        if let start = thread.startLine, start != line {
            return "\(name) lines \(start)–\(line)"
        }
        return "\(name) line \(line)"
    }

    static func summary(_ thread: ReviewThread) -> String {
        let count = thread.comments.count == 1 ? "1 comment" : "\(thread.comments.count) comments"
        guard let first = thread.comments.first else { return count }
        return "\(first.authorLogin) · \(count)"
    }
}

private struct ThreadBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }
}
