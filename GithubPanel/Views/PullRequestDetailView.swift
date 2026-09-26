import SwiftUI
import AppKit

enum PullRequestDetailTab: String, CaseIterable, Identifiable {
    case conversation
    case files

    var id: String { rawValue }
}

struct PullRequestDetailView: View {
    @StateObject private var viewModel: PullRequestDetailViewModel
    @State private var selectedTab: PullRequestDetailTab = .conversation
    @State private var isEditingTitle = false
    /// Goes up by one each time the comment box should take focus.
    @State private var commentFocusRequest = 0

    init(viewModel: @autoclosure @escaping () -> PullRequestDetailViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let content = viewModel.content {
                PullRequestDetailHeader(detail: content.detail,
                                        isLoading: viewModel.isLoading,
                                        isEditingTitle: $isEditingTitle,
                                        onRefresh: reload,
                                        onSaveTitle: { title in try await viewModel.edit(title: title) })
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                if let error = viewModel.errorMessage {
                    errorText(error)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }

                Picker("", selection: $selectedTab) {
                    Text(conversationTitle).tag(PullRequestDetailTab.conversation)
                    Text("Files changed \(content.files.count)").tag(PullRequestDetailTab.files)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                Divider()

                switch selectedTab {
                case .conversation:
                    PullRequestConversationView(detail: content.detail,
                                                comments: viewModel.comments?.comments,
                                                commentFocusRequest: commentFocusRequest,
                                                onComment: { body in try await viewModel.post(.general(body: body)) },
                                                onSaveBody: { body in try await viewModel.edit(body: body) })
                case .files:
                    PullRequestFilesView(viewModel: viewModel,
                                         files: content.files,
                                         filesURL: content.detail.htmlURL.appendingPathComponent("files"))
                }
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    errorText(error)
                    Button("Try Again", action: reload)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 420, minHeight: 400)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(navigationTitle)
        .focusedSceneValue(\.pullRequestDetail, actions)
        .task {
            await viewModel.load()
        }
    }

    private var conversationTitle: String {
        guard let count = viewModel.comments?.comments.count, count > 0 else { return "Conversation" }
        return "Conversation \(count)"
    }

    private var navigationTitle: String {
        let reference = viewModel.reference
        guard let title = viewModel.content?.detail.title else { return reference.id }
        return "\(title) · \(reference.id)"
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }

    private func reload() {
        Task { await viewModel.load() }
    }

    private func addComment() {
        guard selectedTab != .conversation else {
            commentFocusRequest += 1
            return
        }
        // Ask once the Conversation tab is on screen, so its comment box sees the request change.
        selectedTab = .conversation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { commentFocusRequest += 1 }
    }

    private var actions: PullRequestDetailActions? {
        guard let detail = viewModel.content?.detail else { return nil }
        return PullRequestDetailActions(htmlURL: detail.htmlURL,
                                        branch: detail.headRef,
                                        reload: reload,
                                        showPreviousTab: { selectedTab = selectedTab.previous },
                                        showNextTab: { selectedTab = selectedTab.next },
                                        addComment: addComment,
                                        editTitle: detail.canEdit ? { isEditingTitle = true } : nil)
    }
}

struct PullRequestDetailHeader: View {
    let detail: PullRequestDetail
    let isLoading: Bool
    @Binding var isEditingTitle: Bool
    let onRefresh: () -> Void
    /// Saves a new title. Throws to keep the draft and show the error.
    let onSaveTitle: (String) async throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEditingTitle {
                PullRequestTitleEditor(title: detail.title,
                                       onCancel: { isEditingTitle = false },
                                       onSave: { title in
                                           try await onSaveTitle(title)
                                           isEditingTitle = false
                                       })
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleText
                    Text("#\(String(detail.reference.number))")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    if detail.canEdit {
                        Button {
                            isEditingTitle = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit title")
                    }

                    Spacer(minLength: 12)

                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .help("Reload")

                    Button("Open on GitHub") {
                        NSWorkspace.shared.open(detail.htmlURL)
                    }
                }
            }

            HStack(spacing: 8) {
                PullRequestStateBadge(state: detail.state)

                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 12)

                Text("+\(detail.additions)")
                    .foregroundStyle(DiffColors.additionText)
                Text("−\(detail.deletions)")
                    .foregroundStyle(DiffColors.deletionText)
            }
            .font(.callout.monospacedDigit())
        }
    }

    /// An editable title opens its editor on double-click, so it gives up text selection.
    @ViewBuilder
    private var titleText: some View {
        let title = Text(detail.title)
            .font(.title2.weight(.semibold))
        if detail.canEdit {
            title
                .onTapGesture(count: 2) { isEditingTitle = true }
                .help("Double-click to edit the title")
        } else {
            title
                .textSelection(.enabled)
        }
    }

    private var summaryText: String {
        let commits = detail.commits == 1 ? "1 commit" : "\(detail.commits) commits"
        return "\(detail.authorLogin) wants to merge \(commits) into \(detail.baseRef) from \(detail.headRef) · \(detail.reference.repoFullName)"
    }
}

/// Edits the title in place, like GitHub. Return or ⌘Return saves and Escape cancels.
/// Keeps the draft and shows the error when GitHub refuses it.
struct PullRequestTitleEditor: View {
    let onCancel: () -> Void
    let onSave: (String) async throws -> Void

    @State private var title: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(title: String,
         onCancel: @escaping () -> Void,
         onSave: @escaping (String) async throws -> Void) {
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($isFocused)
                    .disabled(isSaving)
                    .onSubmit(save)
                    .onExitCommand(perform: onCancel)
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                saveButton
                Button("Cancel", action: onCancel)
                    .disabled(isSaving)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            // The text view is not in the window yet during onAppear, so focus on the next turn.
            DispatchQueue.main.async { isFocused = true }
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        let button = Button("Save", action: save)
            .buttonStyle(.borderedProminent)
            .disabled(!Self.canSave(title) || isSaving)
            .help("Save (⌘Return)")
        // Only answer ⌘Return while typing, so an open description editor keeps its own shortcut.
        if isFocused {
            button.keyboardShortcut(.return, modifiers: .command)
        } else {
            button
        }
    }

    /// GitHub requires a title, so a blank one cannot be saved.
    static func canSave(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard Self.canSave(title), !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(title)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

enum MarkdownEditorTab: String, CaseIterable, Identifiable {
    case write
    case preview

    var id: String { rawValue }
}

/// Edits the description in place with Write and Preview tabs, like GitHub.
/// Keeps the draft and shows the error when GitHub refuses it.
struct PullRequestBodyEditor: View {
    let onCancel: () -> Void
    let onSave: (String) async throws -> Void

    @State private var text: String
    @State private var tab: MarkdownEditorTab = .write
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(body: String,
         onCancel: @escaping () -> Void,
         onSave: @escaping (String) async throws -> Void) {
        self.onCancel = onCancel
        self.onSave = onSave
        _text = State(initialValue: body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) {
                Text("Write").tag(MarkdownEditorTab.write)
                Text("Preview").tag(MarkdownEditorTab.preview)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Group {
                switch tab {
                case .write:
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .focused($isFocused)
                        .frame(minHeight: 160, maxHeight: 480)
                        .fixedSize(horizontal: false, vertical: true)
                        .onExitCommand(perform: onCancel)
                case .preview:
                    Group {
                        if Self.isBlank(text) {
                            Text("Nothing to preview")
                                .italic()
                                .foregroundStyle(.secondary)
                        } else {
                            MarkdownView(markdown: text)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
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
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel", action: onCancel)
                    .disabled(isSaving)
                saveButton
            }
        }
        .onAppear {
            // The text view is not in the window yet during onAppear, so focus on the next turn.
            DispatchQueue.main.async { isFocused = true }
        }
        .onChange(of: tab) { tab in
            if tab == .write { isFocused = true }
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        let button = Button("Update description", action: save)
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
            .help("Update description (⌘Return)")
        // Only answer ⌘Return while typing, so the comment composer below keeps its own shortcut.
        if isFocused {
            button.keyboardShortcut(.return, modifiers: .command)
        } else {
            button
        }
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(text)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

struct PullRequestStateBadge: View {
    let state: PullRequestDetail.State

    var body: some View {
        Label(title, systemImage: iconName)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color))
            .foregroundStyle(.white)
    }

    private var title: String {
        switch state {
        case .open: return "Open"
        case .draft: return "Draft"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    private var iconName: String {
        switch state {
        case .open, .draft: return "arrow.triangle.pull"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }

    private var color: Color {
        switch state {
        case .open: return Color(red: 0.12, green: 0.53, blue: 0.24)
        case .draft: return Color(red: 0.40, green: 0.43, blue: 0.47)
        case .merged: return Color(red: 0.51, green: 0.31, blue: 0.85)
        case .closed: return Color(red: 0.81, green: 0.13, blue: 0.18)
        }
    }
}

struct PullRequestConversationView: View {
    let detail: PullRequestDetail
    /// General comments, oldest first. Nil while they load.
    let comments: [PullRequestComment]?
    /// Goes up by one each time the comment box should take focus.
    var commentFocusRequest = 0
    let onComment: (String) async throws -> Void
    /// Saves a new description. Throws to keep the draft and show the error.
    let onSaveBody: (String) async throws -> Void

    @State private var isEditingBody = false

    private static let composerID = "comment-composer"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("\(detail.authorLogin) opened this pull request \(detail.createdAt.formatted(.relative(presentation: .named)))")
                                .font(.callout.weight(.semibold))
                            Spacer(minLength: 8)
                            if detail.canEdit && !isEditingBody {
                                Button {
                                    isEditingBody = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Edit description")
                            }
                        }

                        Group {
                            if isEditingBody {
                                PullRequestBodyEditor(body: detail.body,
                                                      onCancel: { isEditingBody = false },
                                                      onSave: { body in
                                                          try await onSaveBody(body)
                                                          isEditingBody = false
                                                      })
                            } else if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("No description provided.")
                                    .italic()
                                    .foregroundStyle(.secondary)
                            } else {
                                MarkdownView(markdown: detail.body)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }

                    if let comments {
                        ForEach(comments) { comment in
                            PullRequestCommentView(comment: comment)
                                .padding(16)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add a comment")
                            .font(.callout.weight(.semibold))
                        CommentComposer(placeholder: "Leave a comment (Markdown supported)",
                                        submitTitle: "Comment",
                                        focusRequest: commentFocusRequest,
                                        onSubmit: onComment)
                    }
                    .id(Self.composerID)
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .background(PageScrollAnchor())
            }
            .onChange(of: commentFocusRequest) { _ in
                withAnimation { proxy.scrollTo(Self.composerID, anchor: .bottom) }
            }
        }
    }
}

struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlocks.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.inline(text))
                    .font(level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                if level <= 2 {
                    Divider()
                }
            }
            .padding(.top, 4)
        case let .paragraph(text):
            Text(Self.inline(text))
        case let .listItem(marker, indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 18)
        case let .quote(text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 3)
                }
        case let .code(_, text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        case let .table(header, alignments, rows):
            MarkdownTableView(header: header, alignments: alignments, rows: rows)
        case .rule:
            Divider()
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A GitHub-style pipe table: bold header, row dividers, and a rounded border.
private struct MarkdownTableView: View {
    let header: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    cell(header[column], column: column)
                        .font(.body.weight(.semibold))
                        .background(Color.secondary.opacity(0.08))
                }
            }
            ForEach(rows.indices, id: \.self) { row in
                Divider()
                GridRow {
                    ForEach(rows[row].indices, id: \.self) { column in
                        cell(rows[row][column], column: column)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.3))
        )
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .leading
        return Text(MarkdownView.inline(text))
            .multilineTextAlignment(alignment.textAlignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frameAlignment)
            .overlay(alignment: .leading) {
                if column > 0 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 1)
                }
            }
    }
}

private extension MarkdownTableAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

enum DiffColors {
    static let additionText = Color(red: 0.10, green: 0.50, blue: 0.22)
    static let deletionText = Color(red: 0.81, green: 0.13, blue: 0.18)
    static let additionBackground = Color.green.opacity(0.14)
    static let deletionBackground = Color.red.opacity(0.12)
    static let hunkBackground = Color.blue.opacity(0.08)
    /// Stronger fills for the words that changed inside a line.
    static let additionHighlight = Color.green.opacity(0.4)
    static let deletionHighlight = Color.red.opacity(0.32)

    static func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: return additionBackground
        case .deletion: return deletionBackground
        case .hunk: return hunkBackground
        case .context, .note: return .clear
        }
    }

    static func gutterBackground(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition, .deletion, .hunk: return background(for: kind)
        case .context, .note: return Color.secondary.opacity(0.04)
        }
    }

    /// The line's text with its changed words filled in.
    static func attributedText(_ line: DiffDisplayLine) -> AttributedString {
        let highlight = line.kind == .addition ? additionHighlight : deletionHighlight
        var text = AttributedString()
        for segment in line.segments {
            var part = AttributedString(segment.text)
            if segment.isChanged {
                part.backgroundColor = highlight
            }
            text += part
        }
        return text.characters.isEmpty ? AttributedString(" ") : text
    }
}
