import SwiftUI
import AppKit

enum PullRequestDetailTab: String, CaseIterable, Identifiable {
    case conversation
    case files
    case checks

    var id: String { rawValue }
}

struct PullRequestDetailView: View {
    @AppStorage(PullRequestTextSize.defaultsKey) private var prTextSize = PullRequestTextSize.defaultSize
    @StateObject private var viewModel: PullRequestDetailViewModel
    @State private var selectedTab: PullRequestDetailTab = .conversation
    @State private var isEditingTitle = false
    @State private var isReviewing = false
    /// Set in the main window, where the toolbar sits in the title bar strip.
    @Environment(\.titleBarHeight) private var titleBarHeight
    /// Goes up by one each time the comment box should take focus.
    @State private var commentFocusRequest = 0

    init(viewModel: @autoclosure @escaping () -> PullRequestDetailViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let content = viewModel.content {
                PullRequestDetailToolbar(selectedTab: $selectedTab,
                                         segments: tabSegments(fileCount: content.files.count),
                                         htmlURL: content.detail.htmlURL,
                                         isLoading: viewModel.isLoading,
                                         onRefresh: reload,
                                         isUpdatingBranch: viewModel.isUpdatingBranch,
                                         onUpdateBranch: content.detail.offersUpdateBranch || (content.detail.isViewerAuthor && viewModel.isUpdatingBranch) ? {
                                             Task { await viewModel.updateBranch() }
                                         } : nil,
                                         isReviewing: $isReviewing,
                                         onSubmitReview: viewModel.canReview ? { event, body in
                                             try await viewModel.submitReview(event, body: body)
                                         } : nil,
                                         pendingCommentCount: viewModel.pendingCommentCount,
                                         onDiscardReview: viewModel.isReviewPending ? {
                                             try await viewModel.discardPendingReview()
                                         } : nil)
                    .padding(.leading, 28)
                    .padding(.trailing, 20)
                    .frame(height: max(titleBarHeight ?? 0, 54))

                PullRequestDetailHeader(detail: content.detail,
                                        isEditingTitle: $isEditingTitle,
                                        onSaveTitle: { title in try await viewModel.edit(title: title) })
                    .padding(.horizontal, 32)
                    .padding(.top, 14)
                    .padding(.bottom, 16)

                if let error = viewModel.errorMessage {
                    errorText(error)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 8)
                }

                if let review = viewModel.submittedReview {
                    Label(review.confirmation, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.green)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 10)
                }

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 32)

                switch selectedTab {
                case .conversation:
                    PullRequestConversationView(detail: content.detail,
                                                comments: viewModel.comments?.comments,
                                                commentFocusRequest: commentFocusRequest,
                                                onComment: { body in try await viewModel.post(.general(body: body)) },
                                                onSaveBody: { body in try await viewModel.edit(body: body) },
                                                onSetTask: { index, checked in
                                                    Task { await viewModel.setTask(index, checked: checked) }
                                                })
                case .files:
                    PullRequestFilesView(viewModel: viewModel,
                                         files: content.files,
                                         filesURL: content.detail.htmlURL.appendingPathComponent("files"))
                case .checks:
                    PullRequestChecksView(checks: viewModel.checks,
                                          rerunsInFlight: viewModel.rerunsInFlight,
                                          onRerun: { rerun in Task { await viewModel.rerun(rerun) } },
                                          onRerunFailed: { Task { await viewModel.rerunFailedChecks() } })
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
        .prFont(.body)
        .environment(\.pullRequestTextSize, prTextSize)
        .navigationTitle(navigationTitle)
        .focusedSceneValue(\.pullRequestDetail, actions)
        .task {
            await viewModel.load()
        }
    }

    private func tabSegments(fileCount: Int) -> [GlassSegmentedControl<PullRequestDetailTab>.Segment] {
        [.init(value: .conversation, title: conversationTitle),
         .init(value: .files, title: "Files changed \(fileCount)"),
         .init(value: .checks, title: Self.checksTitle(viewModel.checks))]
    }

    /// "Checks", "Checks 12", or "Checks 2 failing" so a red X shows before the tab is opened.
    static func checksTitle(_ checks: PullRequestChecks?) -> String {
        guard let checks, !checks.checks.isEmpty else { return "Checks" }
        let failing = checks.count(.failure)
        return failing > 0 ? "Checks \(failing) failing" : "Checks \(checks.checks.count)"
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
                                        editTitle: detail.canEdit ? { isEditingTitle = true } : nil,
                                        review: viewModel.canReview ? { isReviewing = true } : nil)
    }
}

/// The row over the pull request: the Conversation / Files changed / Checks switcher on the left and the
/// Reload, Update branch, Review and Open on GitHub buttons in glass capsules on the right. Edit title sits by the title instead.
struct PullRequestDetailToolbar: View {
    @Binding var selectedTab: PullRequestDetailTab
    let segments: [GlassSegmentedControl<PullRequestDetailTab>.Segment]
    let htmlURL: URL
    let isLoading: Bool
    let onRefresh: () -> Void
    var isUpdatingBranch = false
    /// Merges the base branch into this branch. Nil when GitHub does not offer Update branch.
    var onUpdateBranch: (() -> Void)?
    /// Whether the review form is open over the Review button.
    @Binding var isReviewing: Bool
    /// Submits a review. Nil when you cannot review this pull request, such as your own.
    var onSubmitReview: ((PullRequestReviewEvent, String) async throws -> Void)?
    /// Draft comments in the pending review, shown on the Review button.
    var pendingCommentCount = 0
    /// Discards the pending review. Nil when no review is pending.
    var onDiscardReview: (() async throws -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            GlassSegmentedControl(selection: $selectedTab, segments: segments)
                .fixedSize()

            Spacer(minLength: 12)

            Button(action: onRefresh) {
                toolbarIcon("arrow.clockwise")
            }
            .disabled(isLoading)
            .help("Reload")
            .accessibilityLabel("Reload")
            .buttonStyle(.plain)
            .padding(.horizontal, 3)
            .frame(height: 34)
            .glassSurface(.control, in: Capsule())

            if let onUpdateBranch {
                Button(action: onUpdateBranch) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 12, weight: .semibold))
                        Text(isUpdatingBranch ? "Updating..." : "Update branch")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isUpdatingBranch)
                .glassSurface(.control, in: Capsule())
                .help("Merge the latest changes from the base branch into this branch")
            }

            if let onSubmitReview {
                Button {
                    isReviewing.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.bubble")
                            .font(.system(size: 12, weight: .semibold))
                        Text(onDiscardReview == nil ? "Review" : "Finish review")
                        if pendingCommentCount > 0 {
                            Text("\(pendingCommentCount)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                                .accessibilityLabel(ReviewComposer.pendingSummary(pendingCommentCount))
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassSurface(.control, in: Capsule())
                .help("Approve, comment, or request changes (\(AppShortcut.reviewChanges.symbols))")
                .popover(isPresented: $isReviewing, arrowEdge: .bottom) {
                    ReviewComposer(pendingCommentCount: pendingCommentCount,
                                   onCancel: { isReviewing = false },
                                   onSubmit: { event, body in
                                       try await onSubmitReview(event, body)
                                       isReviewing = false
                                   },
                                   onDiscard: onDiscardReview.map { discard in
                                       {
                                           try await discard()
                                           isReviewing = false
                                       }
                                   })
                }
            }

            Button {
                NSWorkspace.shared.open(htmlURL)
            } label: {
                HStack(spacing: 6) {
                    Text("Open on GitHub")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.leading, 16)
                .padding(.trailing, 14)
                .frame(height: 34)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassSurface(.control, in: Capsule())
        }
    }

    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 28)
            .contentShape(Capsule())
    }
}

struct PullRequestDetailHeader: View {
    let detail: PullRequestDetail
    @Binding var isEditingTitle: Bool
    /// Saves a new title. Throws to keep the draft and show the error.
    let onSaveTitle: (String) async throws -> Void
    @State private var copiedBranchNotice = false

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
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleText
                    Text("#\(String(detail.reference.number))")
                        .prFont(size: 26, weight: .regular)
                        .foregroundStyle(.tertiary)
                    if Self.showsEditTitleButton(for: detail) {
                        editTitleButton
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 8) {
                PullRequestStateBadge(state: detail.state)

                summary
                    .prFont(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)

                if copiedBranchNotice {
                    Text("Copied")
                        .prFont(.caption1, weight: .medium)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Spacer(minLength: 12)

                Text("+\(detail.additions)")
                    .foregroundStyle(DiffColors.additionText)
                Text("−\(detail.deletions)")
                    .foregroundStyle(DiffColors.deletionText)
            }
            .prFont(.callout)
            .monospacedDigit()
        }
    }

    /// Only the author can rename a pull request, so only they get the pencil.
    static func showsEditTitleButton(for detail: PullRequestDetail) -> Bool {
        detail.canEdit
    }

    /// A quiet pencil right after the title, so it is clear the button edits the title.
    private var editTitleButton: some View {
        Button {
            isEditingTitle = true
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Edit title")
        .accessibilityLabel("Edit title")
    }

    /// An editable title opens its editor on double-click, so it gives up text selection.
    @ViewBuilder
    private var titleText: some View {
        let title = Text(detail.title)
            .prFont(size: 26, weight: .bold)
            .tracking(-0.5)
        if detail.canEdit {
            title
                .onTapGesture(count: 2) { isEditingTitle = true }
                .help("Double-click to edit the title")
        } else {
            title
                .textSelection(.enabled)
        }
    }

    /// "octocat wants to merge 2 commits into [main] from [feature] · owner/repo", with each branch
    /// as a tag that copies its name, like GitHub.
    private var summary: some View {
        HStack(spacing: 5) {
            Text(Self.summaryLead(for: detail))
                .lineLimit(1)
                .layoutPriority(2)
            BranchTag(name: detail.baseRef, onCopy: showCopiedBranch)
            Text("from")
                .fixedSize()
            BranchTag(name: detail.headRef, onCopy: showCopiedBranch)
                .layoutPriority(1)
            Text("· \(detail.reference.repoFullName)")
                .lineLimit(1)
        }
    }

    static func summaryLead(for detail: PullRequestDetail) -> String {
        let commits = detail.commits == 1 ? "1 commit" : "\(detail.commits) commits"
        return "\(detail.authorLogin) wants to merge \(commits) into"
    }

    private func showCopiedBranch() {
        withAnimation(.easeOut(duration: 0.15)) { copiedBranchNotice = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) { copiedBranchNotice = false }
        }
    }
}

/// A branch name in a soft blue tag, like GitHub's. Clicking it copies the name.
struct BranchTag: View {
    let name: String
    let onCopy: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            Pasteboard.copy(name)
            onCopy()
        } label: {
            Text(name)
                .prFont(.callout, design: .monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Theme.branch)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? Theme.branchFillHover : Theme.branchFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Copy branch name")
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
                    .prFont(.title3)
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
                    .prFont(.caption1)
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
                        .prFont(.body)
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
                        .prFont(.caption1)
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
            .prFont(.caption1, weight: .semibold)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 24)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(state == .draft ? 0 : 0.28), lineWidth: 0.5))
            .foregroundStyle(color)
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
        case .open: return Theme.green
        case .draft: return .secondary
        case .merged: return Theme.purple
        case .closed: return Theme.red
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
    /// Checks or unchecks a task item in the description: its index and the new state.
    var onSetTask: (Int, Bool) -> Void = { _, _ in }

    @State private var isEditingBody = false
    @State private var paneWidth: CGFloat = 0

    /// The description and comments column, as wide as it was before the sidebar.
    static let mainColumnMaxWidth: CGFloat = 836
    /// GitHub's sidebar sits beside the description at a fixed width.
    static let sidebarWidth: CGFloat = 220
    static let sidebarSpacing: CGFloat = 28
    static let horizontalPadding: CGFloat = 32
    /// Below this the description would get too narrow, so the sidebar moves above it, as on GitHub's narrow layout.
    static let minimumMainColumnWidth: CGFloat = 420

    static func showsSidebar(paneWidth: CGFloat) -> Bool {
        paneWidth >= 2 * horizontalPadding + minimumMainColumnWidth + sidebarSpacing + sidebarWidth
    }

    private var showsSidebar: Bool { Self.showsSidebar(paneWidth: paneWidth) }

    private var contentMaxWidth: CGFloat {
        2 * Self.horizontalPadding + Self.mainColumnMaxWidth + (showsSidebar ? Self.sidebarSpacing + Self.sidebarWidth : 0)
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: Self.sidebarSpacing) {
                mainColumn
                    .frame(maxWidth: Self.mainColumnMaxWidth, alignment: .leading)
                if showsSidebar {
                    sidebar
                        .frame(width: Self.sidebarWidth)
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .background(PageScrollAnchor())
            // Fill the pane so the scroll view, and its scroller, reach the window's right edge.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ConversationPaneWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(ConversationPaneWidthKey.self) { paneWidth = $0 }
        // The comment box floats in glass over the bottom of the conversation, which scrolls under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CommentComposer(placeholder: "Leave a comment (Markdown supported)",
                            submitTitle: "Comment",
                            style: .floating,
                            focusRequest: commentFocusRequest,
                            onSubmit: onComment)
                .frame(maxWidth: Self.mainColumnMaxWidth)
                .padding(.leading, Self.horizontalPadding)
                .padding(.trailing, Self.horizontalPadding + (showsSidebar ? Self.sidebarSpacing + Self.sidebarWidth : 0))
                .padding(.bottom, 20)
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sidebar: some View {
        PullRequestReviewersView(reviewers: detail.reviewers)
            .padding(.top, 4)
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !showsSidebar {
                sidebar
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    AvatarView(login: detail.authorLogin)
                    Text(detail.authorLogin)
                        .prFont(.callout, weight: .semibold)
                    Text("opened this pull request \(detail.createdAt.formatted(.relative(presentation: .named)))")
                        .prFont(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if detail.canEdit && !isEditingBody {
                        Button {
                            isEditingBody = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(QuietButtonStyle())
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
                        MarkdownView(markdown: detail.body, onSetTask: detail.canEdit ? onSetTask : nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 18)
            .conversationCard()

            if let comments {
                ForEach(comments) { comment in
                    PullRequestCommentView(comment: comment)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 15)
                        .conversationCard()
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct ConversationPaneWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MarkdownView: View {
    let markdown: String
    /// Checks or unchecks a task item: its index and the new state. Nil shows the boxes disabled, as GitHub does for readers.
    var onSetTask: ((Int, Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlocks.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .prFont(.body)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.inline(text))
                    .prFont(level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .semibold)
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
        case let .task(index, checked, indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Toggle("", isOn: Binding(get: { checked }, set: { onSetTask?(index, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(onSetTask == nil)
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
                    .prFont(size: 12, design: .monospaced)
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
                        .prFont(.body, weight: .semibold)
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

extension View {
    /// The soft rounded card behind the description and each comment.
    func conversationCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
        return background(shape.fill(Theme.conversationCardFill))
            .overlay(shape.strokeBorder(Theme.conversationCardBorder, lineWidth: 1))
    }
}
