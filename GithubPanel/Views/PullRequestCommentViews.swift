import SwiftUI
import AppKit

/// One comment: who wrote it, when, and its Markdown body.
struct PullRequestCommentView: View {
    let comment: PullRequestComment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AvatarView(login: comment.authorLogin)
                Text(comment.authorLogin)
                    .prFont(.callout, weight: .semibold)
                if comment.isPending {
                    ThreadBadge(text: "Pending")
                        .help("A draft in your pending review. Only you can see it until you submit the review.")
                }
                Text("commented \(comment.createdAt.formatted(.relative(presentation: .named)))")
                    .prFont(.callout)
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
    enum Style {
        /// A bordered box with its buttons underneath, for replies and comments on diff lines.
        case inline
        /// A one-line glass bar with the button beside the text, floating over the conversation.
        case floating
    }

    let placeholder: String
    let submitTitle: String
    var style: Style = .inline
    /// Shows a Cancel button and handles Escape. Nil for the always-visible composer on the Conversation tab.
    var onCancel: (() -> Void)?
    /// Takes focus each time this goes up.
    var focusRequest = 0
    /// Posts the trimmed text. Throws to keep the draft and show the error.
    let onSubmit: (String) async throws -> Void
    /// A plain button beside the main one that posts the text another way, such as Add single comment next to Start a review.
    var secondaryTitle: String?
    var onSecondarySubmit: ((String) async throws -> Void)?

    @State private var text = ""
    @State private var isPosting = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            switch style {
            case .inline: inlineBody
            case .floating: floatingBody
            }
        }
        .prFont(.body)
        .onAppear {
            // An inline composer opens from a click on a line, so start typing right away.
            if onCancel != nil { isFocused = true }
        }
        .onChange(of: focusRequest) { _ in
            isFocused = true
        }
    }

    private var floatingBody: some View {
        let shape = RoundedRectangle(cornerRadius: 23, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                errorText(errorMessage)
                    .padding(.horizontal, 18)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .prFont(.body)
                        .scrollContentBackground(.hidden)
                        .focused($isFocused)
                        .frame(minHeight: 22, maxHeight: 160)
                        .fixedSize(horizontal: false, vertical: true)
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.vertical, 5)
                if isPosting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 8)
                }
                submitButton
                    .controlSize(.large)
                    .capsuleButtonShape()
            }
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .glassSurface(.control, in: shape)
            .overlay(shape.strokeBorder(Color.accentColor.opacity(isFocused ? 0.5 : 0), lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .prFont(.caption1)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .lineLimit(3)
    }

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .prFont(.body)
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
            )

            HStack(spacing: 8) {
                if let errorMessage {
                    errorText(errorMessage)
                }
                Spacer(minLength: 8)
                if isPosting {
                    ProgressView().controlSize(.small)
                }
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .disabled(isPosting)
                }
                if let secondaryTitle, let onSecondarySubmit {
                    Button(secondaryTitle) { submit(with: onSecondarySubmit) }
                        .disabled(Self.trimmed(text).isEmpty || isPosting)
                }
                submitButton
            }
        }
    }

    @ViewBuilder
    private var submitButton: some View {
        let button = Button(submitTitle) { submit(with: onSubmit) }
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

    private func submit(with action: @escaping (String) async throws -> Void) {
        let body = Self.trimmed(text)
        guard !body.isEmpty, !isPosting else { return }
        isPosting = true
        errorMessage = nil
        Task {
            do {
                try await action(body)
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

/// A review thread on the diff: its comments, a reply box, and a button to resolve or unresolve it.
/// Resolved threads start folded, like on GitHub.
struct ReviewThreadView: View {
    let thread: ReviewThread
    /// Whether a reply joins the viewer's pending review instead of posting right away.
    var isReviewPending = false
    let onReply: (String) async throws -> Void
    /// Resolves (true) or unresolves (false) the thread. Throws to show the error.
    let onSetResolved: (Bool) async throws -> Void

    @State private var isExpanded: Bool
    @State private var isReplying = false
    @State private var isResolving = false
    @State private var resolveError: String?

    init(thread: ReviewThread,
         isReviewPending: Bool = false,
         onReply: @escaping (String) async throws -> Void,
         onSetResolved: @escaping (Bool) async throws -> Void = { _ in }) {
        self.thread = thread
        self.isReviewPending = isReviewPending
        self.onReply = onReply
        self.onSetResolved = onSetResolved
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
                                        submitTitle: isReviewPending ? "Add review comment" : "Reply",
                                        onCancel: { isReplying = false },
                                        onSubmit: { body in
                                            try await onReply(body)
                                            isReplying = false
                                        })
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
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
                                // GitHub cannot resolve a thread that is still a draft.
                                if !thread.isPending {
                                    resolveButton
                                }
                            }
                            if let resolveError {
                                Text(resolveError)
                                    .prFont(.caption1)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .prFont(.body)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private var resolveButton: some View {
        HStack(spacing: 6) {
            if isResolving {
                ProgressView().controlSize(.small)
            }
            Button(Self.resolveTitle(thread), action: toggleResolved)
                .disabled(isResolving)
                .help(thread.isResolved ? "Mark this conversation as unresolved" : "Mark this conversation as resolved")
        }
    }

    private func toggleResolved() {
        guard !isResolving else { return }
        let resolved = !thread.isResolved
        isResolving = true
        resolveError = nil
        Task {
            do {
                try await onSetResolved(resolved)
                // Fold a thread once it is resolved, like GitHub does.
                if resolved { isExpanded = false }
            } catch {
                resolveError = error.localizedDescription
            }
            isResolving = false
        }
    }

    static func resolveTitle(_ thread: ReviewThread) -> String {
        thread.isResolved ? "Unresolve conversation" : "Resolve conversation"
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .prFont(.caption2, weight: .bold)
                    .frame(width: 10)
                Text(Self.title(thread))
                    .prFont(.callout, weight: .semibold)
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
                        .prFont(.callout)
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
            .prFont(.caption2, weight: .bold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }
}

private extension View {
    /// A capsule button, like the Comment button on the floating comment bar. Needs macOS 14.
    @ViewBuilder
    func capsuleButtonShape() -> some View {
        if #available(macOS 14.0, *) {
            buttonBorderShape(.capsule)
        } else {
            self
        }
    }
}
