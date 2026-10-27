import SwiftUI
import AppKit

enum PullRequestDetailTab: String, CaseIterable, Identifiable {
    case conversation
    case files

    var id: String { rawValue }
}

struct PullRequestDetailView: View {
    @AppStorage(PullRequestTextSize.defaultsKey, store: AppDefaults.store) private var prTextSize = PullRequestTextSize.defaultSize
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
                                         tabs: tabs(for: content.detail),
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
                    .padding(.leading, 24)
                    .padding(.trailing, 16)
                    .frame(height: max(titleBarHeight ?? 0, 54))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }

                PullRequestDetailHeader(detail: content.detail,
                                        isEditingTitle: $isEditingTitle,
                                        onSaveTitle: { title in try await viewModel.edit(title: title) })
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
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

                // The conversation flows on from the header; the diff gets a line above it.
                if selectedTab != .conversation {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .padding(.horizontal, 32)
                }

                switch selectedTab {
                case .conversation:
                    PullRequestConversationView(detail: content.detail,
                                                comments: viewModel.comments?.comments,
                                                checks: viewModel.checks,
                                                rerunsInFlight: viewModel.rerunsInFlight,
                                                onRerunCheck: { rerun in Task { await viewModel.rerun(rerun) } },
                                                onRerunFailedChecks: { Task { await viewModel.rerunFailedChecks() } },
                                                commentFocusRequest: commentFocusRequest,
                                                onComment: { body in try await viewModel.post(.general(body: body)) },
                                                onSaveBody: { body in try await viewModel.edit(body: body) },
                                                onSetTask: { index, checked in
                                                    Task { await viewModel.setTask(index, checked: checked) }
                                                },
                                                reviewerActions: content.detail.canRequestReviewers ? ReviewerRequestActions(
                                                    inFlight: viewModel.reviewRequestsInFlight,
                                                    loadCandidates: { query in try await viewModel.reviewerCandidates(matching: query) },
                                                    setRequested: { name, kind, requested in
                                                        Task { await viewModel.setReviewRequested(name, kind: kind, requested: requested) }
                                                    }) : nil)
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
        .prFont(.body)
        .environment(\.pullRequestTextSize, prTextSize)
        .navigationTitle(navigationTitle)
        .focusedSceneValue(\.pullRequestDetail, actions)
        .task {
            await viewModel.load()
        }
    }

    private func tabs(for detail: PullRequestDetail) -> [PullRequestDetailTabBar.Tab] {
        [.init(value: .conversation, title: "Conversation", badge: Self.conversationBadge(viewModel.comments?.comments.count)),
         .init(value: .files, title: "Files changed", badge: .diff(additions: detail.additions, deletions: detail.deletions))]
    }

    /// The comment count after Conversation, left off when there are none yet.
    static func conversationBadge(_ commentCount: Int?) -> PullRequestDetailTabBar.Badge? {
        guard let commentCount, commentCount > 0 else { return nil }
        return .count(commentCount)
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

/// The row over the pull request: the Conversation / Files changed tabs on the left and the
/// Reload, Open on GitHub, Update branch and Review buttons on the right. Edit title sits by the title instead.
struct PullRequestDetailToolbar: View {
    @Binding var selectedTab: PullRequestDetailTab
    let tabs: [PullRequestDetailTabBar.Tab]
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
        HStack(spacing: 6) {
            PullRequestDetailTabBar(selection: $selectedTab, tabs: tabs)
                .fixedSize()

            Spacer(minLength: 12)

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16)
            }
            .buttonStyle(DetailToolbarButtonStyle(isIconOnly: true))
            .disabled(isLoading)
            .help("Reload")
            .accessibilityLabel("Reload")

            Button {
                NSWorkspace.shared.open(htmlURL)
            } label: {
                HStack(spacing: 6) {
                    Text("Open on GitHub")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(DetailToolbarButtonStyle())

            if let onUpdateBranch {
                Button(action: onUpdateBranch) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 12, weight: .semibold))
                        Text(isUpdatingBranch ? "Updating..." : "Update branch")
                    }
                }
                .buttonStyle(DetailToolbarButtonStyle(isBordered: true))
                .disabled(isUpdatingBranch)
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
                                .background(Capsule().fill(Theme.contentBackground.opacity(0.25)))
                                .accessibilityLabel(ReviewComposer.pendingSummary(pendingCommentCount))
                        }
                    }
                }
                .buttonStyle(DetailToolbarButtonStyle(isProminent: true))
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
        }
    }
}

/// The toolbar's buttons: quiet text that gets a soft fill on hover, a hairline-bordered variant, and a
/// prominent dark one for the main action.
struct DetailToolbarButtonStyle: ButtonStyle {
    var isIconOnly = false
    var isBordered = false
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarButton(configuration: configuration, style: self)
    }

    private struct ToolbarButton: View {
        let configuration: ButtonStyle.Configuration
        let style: DetailToolbarButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: style.isProminent ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, style.isIconOnly ? 7 : 12)
                .frame(height: 30)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: style.isBordered ? 1 : 0))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        private var foreground: Color {
            if style.isProminent { return Theme.contentBackground }
            return style.isIconOnly && !(isHovering && isEnabled) ? .secondary : .primary
        }

        private var fill: Color {
            if style.isProminent {
                return Color.primary.opacity(configuration.isPressed ? 0.75 : isHovering && isEnabled ? 0.85 : 1)
            }
            return Color.primary.opacity(configuration.isPressed ? 0.1 : isHovering && isEnabled ? 0.06 : 0)
        }
    }
}

/// The Conversation / Files changed tabs: flat labels, the selected one on a soft rounded fill,
/// each with an optional count or diff size after its title.
struct PullRequestDetailTabBar: View {
    struct Tab: Identifiable {
        let value: PullRequestDetailTab
        let title: String
        var badge: Badge?
        var id: PullRequestDetailTab { value }
    }

    enum Badge: Equatable {
        case count(Int)
        case diff(additions: Int, deletions: Int)
    }

    @Binding var selection: PullRequestDetailTab
    let tabs: [Tab]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                TabButton(tab: tab, isSelected: tab.value == selection) {
                    selection = tab.value
                }
            }
        }
    }

    private struct TabButton: View {
        let tab: Tab
        let isSelected: Bool
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(tab.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected || isHovering ? Color.primary : Color.secondary)
                    if let badge = tab.badge {
                        BadgeView(badge: badge)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(shape.fill(isSelected ? Theme.tabSelection : isHovering ? Theme.tabHover : Color.clear))
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .focusEffectDisabledIfAvailable()
            .onHover { isHovering = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private struct BadgeView: View {
        let badge: Badge

        var body: some View {
            switch badge {
            case let .count(count):
                Text("\(count)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case let .diff(additions, deletions):
                HStack(spacing: 4) {
                    Text("+\(additions)").foregroundStyle(DiffColors.additionText)
                    Text("−\(deletions)").foregroundStyle(DiffColors.deletionText)
                }
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            }
        }
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
            HStack(spacing: 10) {
                PullRequestStateBadge(state: detail.state)
                Text(detail.reference.repoFullName)
                    .lineLimit(1)
                Text("#\(String(detail.reference.number))")
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            .prFont(.callout)
            .foregroundStyle(.secondary)

            if isEditingTitle {
                PullRequestTitleEditor(title: detail.title,
                                       onCancel: { isEditingTitle = false },
                                       onSave: { title in
                                           try await onSaveTitle(title)
                                           isEditingTitle = false
                                       })
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                    if Self.showsEditTitleButton(for: detail) {
                        editTitleButton
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 6) {
                AvatarView(login: detail.authorLogin, size: 20)
                summary
                if copiedBranchNotice {
                    Text("Copied")
                        .prFont(.caption1, weight: .medium)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .prFont(.callout)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 26, height: 26)
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
            .prFont(size: 22, weight: .semibold)
            .tracking(-0.3)
        if detail.canEdit {
            title
                .onTapGesture(count: 2) { isEditingTitle = true }
                .help("Double-click to edit the title")
        } else {
            title
                .textSelection(.enabled)
        }
    }

    /// "octocat wants to merge 2 commits · 3 days ago · [feature] → [main]", with each branch as a tag that
    /// copies its name, like GitHub.
    private var summary: some View {
        HStack(spacing: 6) {
            Text(detail.authorLogin)
                .fontWeight(.medium)
                .lineLimit(1)
                .layoutPriority(3)
            Text(Self.summaryLead(for: detail))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(2)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(detail.createdAt.formatted(.relative(presentation: .named)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(detail.createdAt.formatted(date: .abbreviated, time: .shortened))
            Text("·")
                .foregroundStyle(.tertiary)
            BranchTag(name: detail.headRef, onCopy: showCopiedBranch)
                .layoutPriority(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityLabel("into")
            BranchTag(name: detail.baseRef, onCopy: showCopiedBranch)
        }
    }

    static func summaryLead(for detail: PullRequestDetail) -> String {
        let commits = detail.commits == 1 ? "1 commit" : "\(detail.commits) commits"
        return "wants to merge \(commits)"
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
    /// The head commit's checks for the sidebar. Nil while they load.
    var checks: PullRequestChecks?
    /// Check reruns GitHub has not answered yet.
    var rerunsInFlight: Set<CheckRerun> = []
    var onRerunCheck: (CheckRerun) -> Void = { _ in }
    var onRerunFailedChecks: () -> Void = {}
    /// Goes up by one each time the comment box should take focus.
    var commentFocusRequest = 0
    let onComment: (String) async throws -> Void
    /// Saves a new description. Throws to keep the draft and show the error.
    let onSaveBody: (String) async throws -> Void
    /// Checks or unchecks a task item in the description: its index and the new state.
    var onSetTask: (Int, Bool) -> Void = { _, _ in }
    /// Set when the viewer may request reviews.
    var reviewerActions: ReviewerRequestActions?

    @State private var isEditingBody = false
    /// Room for the description and comments column beside GitHub's sidebar, plus the pane's side padding.
    static let contentMaxWidth: CGFloat = 2 * 32 + SidebarLayout.mainMaxWidth + SidebarLayout.spacing + SidebarLayout.sidebarWidth
    private static let composerID = "comment-composer"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                SidebarLayout {
                    mainColumn
                    VStack(alignment: .leading, spacing: 14) {
                        PullRequestChangesSection(detail: detail)
                        PullRequestReviewersView(reviewers: detail.reviewers, actions: reviewerActions)
                        PullRequestChecksSection(checks: checks,
                                                 rerunsInFlight: rerunsInFlight,
                                                 onRerun: onRerunCheck,
                                                 onRerunFailed: onRerunFailedChecks)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                .background(PageScrollAnchor())
                // Fill the pane so the scroll view, and its scroller, reach the window's right edge.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: commentFocusRequest) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.composerID, anchor: .bottom)
                }
            }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            description
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.top, 14)
                .padding(.bottom, 20)

            Text("Activity")
                .prFont(.headline, weight: .semibold)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 8) {
                if let comments {
                    ForEach(comments) { comment in
                        PullRequestCommentView(comment: comment)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .activityCard()
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }

                CommentComposer(placeholder: "Leave a comment (Markdown supported)",
                                submitTitle: "Comment",
                                style: .bar,
                                focusRequest: commentFocusRequest,
                                onSubmit: onComment)
                    .id(Self.composerID)
            }
        }
    }

    /// The description as plain reading text, with Edit under it for the author.
    private var description: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                        .lineSpacing(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if detail.canEdit && !isEditingBody {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        isEditingBody = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .help("Edit description")
                }
            }
        }
    }
}

/// GitHub's pull request layout: the main column with a fixed-width sidebar to its right. When the main
/// column would get narrower than `minimumMainWidth`, the sidebar moves above it instead.
/// Takes exactly two subviews: the main column, then the sidebar.
struct SidebarLayout: Layout {
    static let mainMaxWidth: CGFloat = 836
    static let sidebarWidth: CGFloat = 220
    static let spacing: CGFloat = 28
    static let stackedSpacing: CGFloat = 14
    static let minimumMainWidth: CGFloat = 420

    static func showsSidebar(width: CGFloat) -> Bool {
        width >= minimumMainWidth + spacing + sidebarWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.mainMaxWidth + Self.spacing + Self.sidebarWidth
        return frames(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, [frames.main, frames.sidebar]) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> (main: CGRect, sidebar: CGRect, size: CGSize) {
        guard subviews.count == 2 else { return (.zero, .zero, .zero) }
        func height(_ subview: LayoutSubview, width: CGFloat) -> CGFloat {
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        if Self.showsSidebar(width: width) {
            let mainWidth = min(Self.mainMaxWidth, width - Self.spacing - Self.sidebarWidth)
            let main = CGRect(x: 0, y: 0, width: mainWidth, height: height(subviews[0], width: mainWidth))
            let sidebar = CGRect(x: mainWidth + Self.spacing, y: 0,
                                 width: Self.sidebarWidth, height: height(subviews[1], width: Self.sidebarWidth))
            return (main, sidebar, CGSize(width: sidebar.maxX, height: max(main.height, sidebar.height)))
        }
        let mainWidth = min(Self.mainMaxWidth, width)
        let sidebar = CGRect(x: 0, y: 0, width: mainWidth, height: height(subviews[1], width: mainWidth))
        let top = sidebar.height > 0 ? sidebar.maxY + Self.stackedSpacing : 0
        let main = CGRect(x: 0, y: top, width: mainWidth, height: height(subviews[0], width: mainWidth))
        return (main, sidebar, CGSize(width: mainWidth, height: main.maxY))
    }
}

struct MarkdownView: View {
    let markdown: String
    /// Checks or unchecks a task item: its index and the new state. Nil shows the boxes disabled, as GitHub does for readers.
    var onSetTask: ((Int, Bool) -> Void)?

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownBlocks.parse(markdown), onSetTask: onSetTask)
            .prFont(.body)
            .textSelection(.enabled)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        return highlightingCode(parsed)
    }

    /// Colors `inline code` and pads each end with a narrow space so its fill does not hug the letters.
    /// ``inlineText(_:)`` draws the fill.
    static func highlightingCode(_ text: AttributedString) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            var part = AttributedString(text[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                part = AttributedString(inlineCodePadding, attributes: part.runs.first?.attributes ?? .init())
                    + part
                    + AttributedString(inlineCodePadding, attributes: part.runs.first?.attributes ?? .init())
                part.foregroundColor = Theme.inlineCodeText
            }
            result += part
        }
        return result
    }

    /// Inline Markdown as a `Text`, with `inline code` marked for ``InlineCodeRenderer`` to fill. Before
    /// macOS 15 the code gets a square background instead.
    static func inlineText(_ markdown: String) -> Text {
        let text = inline(markdown)
        var result = Text(verbatim: "")
        for run in text.runs {
            var part = AttributedString(text[run.range])
            let segment: Text
            if run.inlinePresentationIntent?.contains(.code) == true {
                if #available(macOS 15.0, *) {
                    segment = Text(part).customAttribute(InlineCodeAttribute())
                } else {
                    part.backgroundColor = Theme.inlineCodeFill
                    segment = Text(part)
                }
            } else {
                segment = Text(part)
            }
            result = Text("\(result)\(segment)")
        }
        return result
    }

    /// A narrow no-break space: a thin space would let a line wrap between it and the code, leaving an
    /// empty patch of fill at the end of one line and the code on the next.
    static let inlineCodePadding = "\u{202F}"
}

/// One line or paragraph of inline Markdown, with `inline code` on a soft rounded fill like GitHub's.
/// Selectable text on macOS skips custom text renderers, so the fills are drawn by a copy of the text
/// laid out the same way behind it, which is not selectable and draws only the fills.
struct InlineMarkdownText: View {
    let markdown: String

    var body: some View {
        let text = MarkdownView.inlineText(markdown)
        if #available(macOS 15.0, *), Self.hasInlineCode(markdown) {
            text.background {
                text
                    .textRenderer(InlineCodeRenderer())
                    .textSelection(.disabled)
                    .accessibilityHidden(true)
            }
        } else {
            text
        }
    }

    static func hasInlineCode(_ markdown: String) -> Bool {
        MarkdownView.inline(markdown).runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }
    }
}

/// Parsed Markdown blocks, stacked. Centered HTML blocks nest another one of these.
private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    var alignment: HorizontalAlignment = .leading
    var onSetTask: ((Int, Bool) -> Void)?

    var body: some View {
        VStack(alignment: alignment, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            VStack(alignment: .leading, spacing: 4) {
                InlineMarkdownText(markdown: text)
                    .prFont(level == 1 ? .title2 : level == 2 ? .title3 : .headline, weight: .semibold)
                if level <= 2 {
                    Divider()
                }
            }
            .padding(.top, 4)
        case let .paragraph(text):
            InlineMarkdownText(markdown: text)
        case let .listItem(marker, indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(.secondary)
                InlineMarkdownText(markdown: text)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case let .task(index, checked, indent, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Toggle("", isOn: Binding(get: { checked }, set: { onSetTask?(index, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(onSetTask == nil)
                InlineMarkdownText(markdown: text)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case let .quote(text):
            InlineMarkdownText(markdown: text)
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.codeBlockFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
        case let .table(header, alignments, rows):
            MarkdownTableView(header: header, alignments: alignments, rows: rows)
        case .rule:
            Divider()
        case let .centered(blocks):
            MarkdownBlocksView(blocks: blocks, alignment: .center, onSetTask: onSetTask)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
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
        return InlineMarkdownText(markdown: text)
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
    /// The tighter card behind each comment and the comment box in the Activity list.
    func activityCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.activityCardCornerRadius, style: .continuous)
        return background(shape.fill(Theme.conversationCardFill))
            .overlay(shape.strokeBorder(Theme.activityCardBorder, lineWidth: 1))
    }
}

/// Marks the runs of `inline code` in a `Text` so ``InlineCodeRenderer`` can draw their fill.
@available(macOS 15.0, *)
struct InlineCodeAttribute: TextAttribute {}

/// Draws only a rounded fill behind each stretch of `inline code` on a line; ``InlineMarkdownText`` puts
/// the selectable text over it.
@available(macOS 15.0, *)
struct InlineCodeRenderer: TextRenderer {
    static let cornerRadius: CGFloat = 4

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            let runs = line.map { (bounds: $0.typographicBounds.rect, isCode: $0[InlineCodeAttribute.self] != nil) }
            for rect in Self.codeRects(runs) {
                context.fill(Path(roundedRect: rect, cornerRadius: Self.cornerRadius, style: .continuous),
                             with: .color(Theme.inlineCodeFill))
            }
        }
    }

    /// One rect per stretch of neighboring code runs on a line, so a span split into several runs
    /// still gets a single rounded fill.
    static func codeRects(_ runs: [(bounds: CGRect, isCode: Bool)]) -> [CGRect] {
        var rects: [CGRect] = []
        var current: CGRect?
        for run in runs {
            if run.isCode {
                current = current.map { $0.union(run.bounds) } ?? run.bounds
            } else if let rect = current {
                rects.append(rect)
                current = nil
            }
        }
        if let current { rects.append(current) }
        return rects
    }
}
