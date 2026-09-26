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
    @State private var isEditing = false

    init(viewModel: @autoclosure @escaping () -> PullRequestDetailViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let content = viewModel.content {
                PullRequestDetailHeader(detail: content.detail,
                                        isLoading: viewModel.isLoading,
                                        onRefresh: reload,
                                        onEdit: { isEditing = true })
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
                                                onComment: { body in try await viewModel.post(.general(body: body)) })
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
        .sheet(isPresented: $isEditing) {
            if let detail = viewModel.content?.detail {
                PullRequestEditSheet(detail: detail,
                                     onCancel: { isEditing = false },
                                     onSave: { title, body in
                                         try await viewModel.edit(title: title, body: body)
                                         isEditing = false
                                     })
            }
        }
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
}

struct PullRequestDetailHeader: View {
    let detail: PullRequestDetail
    let isLoading: Bool
    let onRefresh: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(detail.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text("#\(String(detail.reference.number))")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help("Reload")

                if detail.canEdit {
                    Button("Edit", action: onEdit)
                        .help("Edit the title and description")
                }

                Button("Open on GitHub") {
                    NSWorkspace.shared.open(detail.htmlURL)
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

    private var summaryText: String {
        let commits = detail.commits == 1 ? "1 commit" : "\(detail.commits) commits"
        return "\(detail.authorLogin) wants to merge \(commits) into \(detail.baseRef) from \(detail.headRef) · \(detail.reference.repoFullName)"
    }
}

/// Edits a pull request's title and description. Keeps the draft and shows the error when GitHub refuses it.
struct PullRequestEditSheet: View {
    let onCancel: () -> Void
    let onSave: (String, String) async throws -> Void

    @State private var title: String
    @State private var bodyText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(detail: PullRequestDetail,
         onCancel: @escaping () -> Void,
         onSave: @escaping (String, String) async throws -> Void) {
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: detail.title)
        _bodyText = State(initialValue: detail.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Pull Request")
                .font(.headline)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $bodyText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 240)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
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
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!Self.canSave(title: title) || isSaving)
                    .help("Save (⌘Return)")
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
    }

    /// GitHub requires a title, so a blank one cannot be saved.
    static func canSave(title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard Self.canSave(title: title), !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(title, bodyText)
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
    let onComment: (String) async throws -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(detail.authorLogin) opened this pull request \(detail.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.callout.weight(.semibold))

                    Group {
                        if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                                    onSubmit: onComment)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
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
