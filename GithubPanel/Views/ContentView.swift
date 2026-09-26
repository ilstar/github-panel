import SwiftUI
import AppKit

enum EmptyPullRequestsBackground {
    static let imageName = "NoPullRequestsBackground"
}

struct ContentView: View {
    @EnvironmentObject private var monitor: PRMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var tokenInput: String = ""
    @State private var isSaving = false
    @State private var now = Date()
    @State private var selectedPRID: String?
    @State private var selectedReviewID: String?
    @State private var selectedHistoryID: String?
    @State private var mergeInFlight: Set<String> = []
    @State private var pageScroller = PageScroller()
    @AppStorage(ListPaneLayout.widthDefaultsKey) private var listPaneWidth: Double = ListPaneLayout.defaultWidth
    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        // A plain HStack instead of HSplitView: HSplitView snaps back to its ideal
        // width whenever the detail pane is replaced for a new selection.
        GeometryReader { proxy in
            HStack(spacing: 0) {
                listPane
                    .frame(width: ListPaneLayout.clampedWidth(listPaneWidth, totalWidth: proxy.size.width))
                ListPaneDivider(width: $listPaneWidth, totalWidth: proxy.size.width)
                detailPane
                    .frame(minWidth: ListPaneLayout.minDetailWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: ListPaneLayout.minWindowWidth, minHeight: 500)
        .background(paneBackgrounds)
        .background(KeyCommandMonitor(handler: handleKeyCommand))
        .focusedSceneValue(\.pullRequestList, listActions)
        .onAppear {
            monitor.start()
        }
        .onReceive(minuteTicker) { tick in
            now = tick
        }
        .onChange(of: monitor.lastRefreshAt) { _ in
            now = Date()
        }
        .onChange(of: monitor.lastHistoryRefreshAt) { _ in
            now = Date()
        }
        .onChange(of: monitor.lastReviewRequestsRefreshAt) { _ in
            now = Date()
        }
    }

    /// Both panes' backgrounds, drawn behind the whole window so they run up under the hidden title bar.
    private var paneBackgrounds: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Theme.listBackground
                    .frame(width: ListPaneLayout.clampedWidth(listPaneWidth, totalWidth: proxy.size.width))
                Color(nsColor: .separatorColor)
                    .frame(width: ListPaneLayout.dividerWidth)
                Color(nsColor: .textBackgroundColor)
            }
        }
        .ignoresSafeArea()
    }

    private var listPane: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 16) {
                if monitor.isUsingMockData {
                    mockDataBanner
                        .padding(.horizontal, 10)
                }

                prSection
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let reference = selectedReference {
            PullRequestDetailView(viewModel: PullRequestDetailViewModel(reference: reference, monitor: monitor))
            .id(reference)
            .environment(\.pageScroller, pageScroller)
            .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
        } else {
            VStack(spacing: 10) {
                Image(systemName: monitor.hasToken ? "arrow.triangle.pull" : "key")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(monitor.hasToken ? "Select a pull request" : "Add a GitHub token to begin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor).ignoresSafeArea())
        }
    }

    private var selectedReference: PullRequestReference? {
        PullRequestSelection.reference(tab: monitor.selectedTab,
                                       openRows: monitor.prRows,
                                       reviewRows: monitor.reviewRequests.rows,
                                       historyRows: monitor.historyRows,
                                       selectedOpenID: selectedPRID,
                                       selectedReviewID: selectedReviewID,
                                       selectedHistoryID: selectedHistoryID)
    }

    private var mockDataBanner: some View {
        Label("Mock GitHub PRs", systemImage: "testtube.2")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .foregroundStyle(Color.accentColor)
    }

    private var tokenCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("GitHub Token", systemImage: "key.fill")
                .font(.headline)
            Text("Create a personal access token in GitHub and paste it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("https://github.com/settings/tokens", destination: URL(string: "https://github.com/settings/tokens")!)
                .font(.caption)
            Text("Permissions needed: `repo` for private repos, or `public_repo` for public-only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("ghp_...", text: $tokenInput)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(isSaving ? "Saving..." : "Save Token") {
                    saveToken()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .padding(.horizontal, 10)
    }

    private var prSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                PullRequestTabPicker(selection: $monitor.selectedTab)

                Spacer()
                refreshPill
                    .fixedSize()
            }
            .padding(.horizontal, 10)

            listTitle
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 4)

            if !monitor.hasToken {
                tokenCallout
            }

            switch monitor.selectedTab {
            case .open:
                openPullRequestsSection
            case .reviews:
                reviewRequestsSection
            case .history:
                historySection
            }
        }
    }

    /// A large heading for the visible tab, like a list title in Things.
    private var listTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: monitor.selectedTab.systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(monitor.selectedTab.tint)
            Text(monitor.selectedTab.title)
                .font(.system(size: 26, weight: .bold))
            if let count = listCount, count > 0 {
                Text(String(count))
                    .font(.system(size: 20, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var listCount: Int? {
        guard monitor.hasToken else { return nil }
        switch monitor.selectedTab {
        case .open:
            return monitor.prRows.count
        case .reviews:
            return monitor.reviewRequests.rows.count
        case .history:
            return nil
        }
    }

    private var openPullRequestsSection: some View {
        Group {
            if let error = monitor.lastError {
                errorNote(error,
                          hint: "Common fixes: ensure your token has `repo` (private) or `public_repo` scopes, and authorize SSO for org repos.")
            }

            if monitor.hasToken {
                openPullRequestsList
            }
        }
    }

    private var openPullRequestsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if monitor.prRows.isEmpty {
                        emptyStateSpacer
                    } else {
                        ForEach(monitor.prRows) { pr in
                            PRRow(
                                pr: pr,
                                isSelected: selectedPRID == pr.id,
                                relativeFormatter: relativeFormatter,
                                now: now,
                                isMerging: mergeInFlight.contains(pr.id),
                                onAction: {
                                    actOnPullRequest(pr: pr)
                                }
                            )
                            .id(pr.id)
                            .onTapGesture {
                                selectedPRID = pr.id
                                didClickRow(pr.htmlURL)
                            }
                            .contextMenu {
                                pullRequestContextMenu(pr.reference, htmlURL: pr.htmlURL)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if selectedPRID == nil {
                    selectedPRID = monitor.prRows.first?.id
                }
            }
            .onChange(of: monitor.prRows.map { $0.id }) { newIDs in
                if selectedPRID == nil || !newIDs.contains(selectedPRID ?? "") {
                    selectedPRID = newIDs.first
                }
            }
            .onChange(of: selectedPRID) { id in
                scrollToSelection(id, with: proxy)
            }
        }
    }

    private var reviewRequestsSection: some View {
        Group {
            if monitor.hasToken {
                switch reviewRequestsDisplayState {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading review requests…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    EmptyStateView(systemImage: "exclamationmark.triangle",
                                   title: "Couldn’t Load Review Requests",
                                   message: message,
                                   tint: .orange) {
                        Button("Try Again") {
                            Task { await monitor.refreshReviewRequests() }
                        }
                        .controlSize(.large)
                    }
                case .empty:
                    EmptyStateView(systemImage: "checkmark",
                                   title: "You’re All Caught Up",
                                   message: "Pull requests waiting for a review from you or your teams will appear here.",
                                   tint: .green)
                case .list:
                    reviewRequestsList
                }
            }
        }
        .onAppear {
            if selectedReviewID == nil {
                selectedReviewID = monitor.reviewRequests.rows.first?.id
            }
        }
        .onChange(of: monitor.reviewRequests.rows.map { $0.id }) { newIDs in
            if selectedReviewID == nil || !newIDs.contains(selectedReviewID ?? "") {
                selectedReviewID = newIDs.first
            }
        }
    }

    private var reviewRequestsDisplayState: ReviewRequestsDisplayState {
        ReviewRequestsDisplayState(requests: monitor.reviewRequests,
                                   isLoading: monitor.isReviewRequestsLoading,
                                   error: monitor.lastReviewRequestsError,
                                   hasLoaded: monitor.lastReviewRequestsRefreshAt != nil)
    }

    private var reviewRequestsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(ReviewRequestGroup.allCases) { group in
                        reviewRequestGroup(group)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selectedReviewID) { id in
                scrollToSelection(id, with: proxy)
            }
        }
    }

    @ViewBuilder
    private func reviewRequestGroup(_ group: ReviewRequestGroup) -> some View {
        let rows = monitor.reviewRequests.rows(in: group)
        // A section heading with a hairline under it, like a heading inside a Things list.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(String(rows.count))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, group == ReviewRequestGroup.allCases.first ? 4 : 20)
        .padding(.bottom, 4)

        if rows.isEmpty {
            Text(group.emptyText)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            ForEach(rows) { pr in
                PRReviewRequestRow(pr: pr,
                                   isSelected: selectedReviewID == pr.id,
                                   relativeFormatter: relativeFormatter,
                                   now: now)
                    .id(pr.id)
                    .onTapGesture {
                        selectedReviewID = pr.id
                        didClickRow(pr.htmlURL)
                    }
                    .contextMenu {
                        pullRequestContextMenu(pr.reference, htmlURL: pr.htmlURL)
                    }
            }
        }
    }

    private var historySection: some View {
        Group {
            if let error = monitor.lastHistoryError {
                errorNote(error, hint: nil)
            }

            if monitor.hasToken {
                VStack(spacing: 6) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                if monitor.historyRows.isEmpty {
                                    emptyStateSpacer
                                } else {
                                    ForEach(monitor.historyRows) { pr in
                                        PRHistoryRow(pr: pr,
                                                     isSelected: selectedHistoryID == pr.id,
                                                     relativeFormatter: relativeFormatter,
                                                     now: now)
                                            .id(pr.id)
                                            .onTapGesture {
                                                selectedHistoryID = pr.id
                                                didClickRow(pr.htmlURL)
                                            }
                                            .contextMenu {
                                                pullRequestContextMenu(pr.reference, htmlURL: pr.htmlURL)
                                            }
                                    }
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        .scrollIndicators(.hidden)
                        .onAppear {
                            monitor.loadHistoryIfNeeded()
                            if selectedHistoryID == nil {
                                selectedHistoryID = monitor.historyRows.first?.id
                            }
                        }
                        .onChange(of: monitor.historyRows.map { $0.id }) { newIDs in
                            if selectedHistoryID == nil || !newIDs.contains(selectedHistoryID ?? "") {
                                selectedHistoryID = newIDs.first
                            }
                        }
                        .onChange(of: selectedHistoryID) { id in
                            scrollToSelection(id, with: proxy)
                        }
                        .onChange(of: monitor.historyPage) { _ in
                            guard let first = monitor.historyRows.first else { return }
                            selectedHistoryID = first.id
                            withAnimation {
                                proxy.scrollTo(first.id, anchor: .top)
                            }
                        }
                    }

                    historyPagination
                }
            }
        }
    }

    private func errorNote(_ message: String, hint: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .foregroundStyle(Theme.red)
                if let hint {
                    Text(hint)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(Theme.red.opacity(0.08))
        )
    }

    private var lastUpdatedView: some View {
        Text("Updated \(lastUpdatedText)")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(width: 110, alignment: .trailing)
    }

    private var lastUpdatedText: String {
        let lastRefreshAt: Date?
        switch monitor.selectedTab {
        case .open:
            return monitor.lastRefreshText(relativeTo: now)
        case .reviews:
            lastRefreshAt = monitor.lastReviewRequestsRefreshAt
        case .history:
            lastRefreshAt = monitor.lastHistoryRefreshAt
        }
        guard let lastRefreshAt else {
            return "Never"
        }
        return relativeFormatter.localizedString(for: lastRefreshAt, relativeTo: now)
    }

    private var refreshPill: some View {
        RefreshPill(isLoading: monitor.isSelectedTabLoading,
                    isEnabled: refreshIsEnabled,
                    lastUpdatedView: lastUpdatedView) {
            refreshSelectedTab()
        }
    }

    private var refreshIsEnabled: Bool {
        guard monitor.hasToken else { return false }
        return !monitor.isSelectedTabLoading
    }

    private var historyPagination: some View {
        HStack(spacing: 4) {
            Button {
                Task { await monitor.loadPreviousHistoryPage() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!monitor.canLoadPreviousHistoryPage)
            .help("Previous page")

            Text(monitor.historyRangeText)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 86)

            Button {
                Task { await monitor.loadNextHistoryPage() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!monitor.canLoadNextHistoryPage)
            .help("Next page")

            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var emptyStateSpacer: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 220)
            .accessibilityHidden(true)
    }

    private var background: some View {
        ZStack {
            Theme.listBackground

            if showsEmptyPullRequestBackground {
                GeometryReader { proxy in
                    Image(EmptyPullRequestsBackground.imageName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .accessibilityHidden(true)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
    }

    private var showsEmptyPullRequestBackground: Bool {
        monitor.selectedTab == .open && monitor.hasToken && monitor.prRows.isEmpty && monitor.lastError == nil
    }

    private func saveToken() {
        isSaving = true
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        monitor.saveToken(token)
        tokenInput = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isSaving = false
        }
    }

    private func actOnPullRequest(pr: PullRequestRow) {
        if mergeInFlight.contains(pr.id) { return }
        mergeInFlight.insert(pr.id)
        Task {
            if pr.isDraft {
                await monitor.requestMarkReady(for: pr)
            } else {
                await monitor.requestMerge(for: pr)
            }
            await MainActor.run {
                _ = mergeInFlight.remove(pr.id)
            }
        }
    }

    private func refreshSelectedTab() {
        Task { await monitor.refreshSelectedTab() }
    }

    private func handleKeyCommand(_ command: KeyCommand) -> Bool {
        switch command {
        case .nextItem:
            moveSelection(delta: 1)
        case .previousItem:
            moveSelection(delta: -1)
        case .open:
            guard let url = selectedPullRequest?.htmlURL else { return false }
            NSWorkspace.shared.open(url)
        case .pageDown:
            pageScroller.page(down: true)
        case .pageUp:
            pageScroller.page(down: false)
        case .showShortcuts:
            openWindow(id: KeyboardShortcutsWindow.id)
        case .toggleViewed:
            // The Files changed tab handles V.
            return false
        }
        return true
    }

    /// The ids of the visible tab's rows, in the order they are drawn.
    private var visibleRowIDs: [String] {
        switch monitor.selectedTab {
        case .open:
            return monitor.prRows.map(\.id)
        case .reviews:
            return ReviewRequestGroup.allCases.flatMap { monitor.reviewRequests.rows(in: $0) }.map(\.id)
        case .history:
            return monitor.historyRows.map(\.id)
        }
    }

    private func moveSelection(delta: Int) {
        switch monitor.selectedTab {
        case .open:
            selectedPRID = ListNavigation.neighbor(of: selectedPRID, in: visibleRowIDs, offset: delta)
        case .reviews:
            selectedReviewID = ListNavigation.neighbor(of: selectedReviewID, in: visibleRowIDs, offset: delta)
        case .history:
            selectedHistoryID = ListNavigation.neighbor(of: selectedHistoryID, in: visibleRowIDs, offset: delta)
        }
    }

    private func scrollToSelection(_ id: String?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(id)
        }
    }

    /// The selected row on the visible tab.
    private var selectedPullRequest: (reference: PullRequestReference, htmlURL: URL)? {
        switch monitor.selectedTab {
        case .open:
            return monitor.prRows.first { $0.id == selectedPRID }.map { ($0.reference, $0.htmlURL) }
        case .reviews:
            return monitor.reviewRequests.rows.first { $0.id == selectedReviewID }.map { ($0.reference, $0.htmlURL) }
        case .history:
            return monitor.historyRows.first { $0.id == selectedHistoryID }.map { ($0.reference, $0.htmlURL) }
        }
    }

    private var listActions: PullRequestListActions {
        PullRequestListActions(refresh: refreshIsEnabled ? refreshSelectedTab : nil,
                               selection: selectedPullRequest.map { selected in
                                   SelectedPullRequestActions(htmlURL: selected.htmlURL,
                                                              openInNewWindow: { openWindow(value: selected.reference) },
                                                              primaryAction: primaryAction)
                               })
    }

    /// The selected row's merge button, for the menu. Only rows on My PRs have one.
    private var primaryAction: PrimaryAction? {
        guard monitor.selectedTab == .open,
              let pr = monitor.prRows.first(where: { $0.id == selectedPRID }) else { return nil }
        let state = MergeButtonState.resolve(for: pr, isWorking: mergeInFlight.contains(pr.id))
        return PrimaryAction(title: state.title, isEnabled: state.isClickable) {
            actOnPullRequest(pr: pr)
        }
    }

    /// Row clicks show the PR on the right and hand the keyboard back to the list; ⌘-click also opens it on GitHub.
    private func didClickRow(_ htmlURL: URL) {
        NSApp.keyWindow?.endTyping()
        if NSEvent.modifierFlags.contains(.command) {
            NSWorkspace.shared.open(htmlURL)
        }
    }

    @ViewBuilder
    private func pullRequestContextMenu(_ reference: PullRequestReference, htmlURL: URL) -> some View {
        Button("Open in New Window") {
            openWindow(value: reference)
        }
        Button("Open on GitHub") {
            NSWorkspace.shared.open(htmlURL)
        }
    }
}

/// Sized to its segments so its leading edge lines up with the pull request list;
/// a wider fixed frame centers the control and indents it past the rows.
struct PullRequestTabPicker: View {
    @Binding var selection: PullRequestTab

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(PullRequestTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}


private extension PullRequestTab {
    var systemImage: String {
        switch self {
        case .open: return "arrow.triangle.pull"
        case .reviews: return "eye"
        case .history: return "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .open: return .accentColor
        case .reviews: return Theme.amber
        case .history: return .secondary
        }
    }
}
