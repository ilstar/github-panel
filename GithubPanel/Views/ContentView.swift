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
    /// The rows last seen on My PRs and To Review, to pick the row that takes a removed one's place.
    @State private var openRowIDs: [String] = []
    @State private var reviewRowIDs: [String] = []
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
            // Both panes run up into the title bar strip, which holds the tab switcher and the pull request's toolbar.
            let titleBarHeight = max(proxy.safeAreaInsets.top, Self.minimumTitleBarHeight)
            HStack(spacing: 0) {
                listPane(titleBarHeight: titleBarHeight)
                    .frame(width: ListPaneLayout.clampedWidth(listPaneWidth, totalWidth: proxy.size.width))
                ListPaneDivider(width: $listPaneWidth, totalWidth: proxy.size.width)
                detailPane
                    .environment(\.titleBarHeight, titleBarHeight)
                    .frame(minWidth: ListPaneLayout.minDetailWidth, maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: ListPaneLayout.minWindowWidth, minHeight: 500)
        // The title bar area sits over the panes' backgrounds, so it takes clicks there, and under the controls
        // in the strip, so they take theirs. It only answers clicks in the title bar strip.
        .background(ZStack {
            paneBackgrounds
            TitleBarDoubleClickArea().ignoresSafeArea()
        })
        .background(WindowToolbarStrip())
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

    /// The window's background, the floating sidebar and the pull request pane, drawn behind the
    /// whole window so they run up under the hidden title bar.
    private var paneBackgrounds: some View {
        GeometryReader { proxy in
            let listWidth = ListPaneLayout.clampedWidth(listPaneWidth, totalWidth: proxy.size.width)
            ZStack(alignment: .topLeading) {
                Theme.windowBackground
                Theme.contentBackground
                    .padding(.leading, listWidth + ListPaneLayout.dividerWidth)
                sidebarPanel
                    .frame(width: listWidth - Theme.sidebarInset * 2 + ListPaneLayout.dividerWidth)
                    .padding(Theme.sidebarInset)
            }
        }
        .ignoresSafeArea()
    }

    /// The list's floating panel. It sits in the window's background, so the rows draw over its gradient.
    private var sidebarPanel: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.sidebarCornerRadius, style: .continuous)
        return ZStack {
            if showsEmptyPullRequestBackground {
                Image(EmptyPullRequestsBackground.imageName)
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .glassSurface(.panel, in: shape)
    }

    /// The title bar strip's height when the window reports none, such as in full screen.
    static let minimumTitleBarHeight: CGFloat = 44
    /// Room kept for the window buttons at the left of the title bar strip, measured from the list pane's
    /// content edge, so the tab switcher starts just after them.
    static let windowButtonsWidth: CGFloat = 76
    /// The list pane's leading padding: the sidebar's inset plus the 6 points that keep rows inside its corners.
    static let listLeadingPadding: CGFloat = Theme.sidebarInset + 6

    private func listPane(titleBarHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The window buttons sit on the left of this strip, and the tab switcher takes the rest of it.
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: Self.windowButtonsWidth)
                PullRequestTabPicker(selection: $monitor.selectedTab)
            }
            .frame(height: titleBarHeight - Theme.sidebarInset)

            if monitor.isUsingMockData {
                mockDataBanner
                    .padding(.horizontal, 10)
            }

            prSection

            // Keeps the refresh button at the bottom even when the list above is short, such as the token form.
            Spacer(minLength: 0)

            refreshPill
                .fixedSize()
        }
        // Rows sit 6 points inside the sidebar panel, so their corners follow the panel's.
        .padding(.leading, Self.listLeadingPadding)
        .padding(.trailing, Theme.sidebarInset + 5)
        .padding(.top, Theme.sidebarInset)
        .padding(.bottom, Theme.sidebarInset + 4)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let reference = selectedReference {
            PullRequestDetailView(viewModel: PullRequestDetailViewModel(reference: reference, monitor: monitor))
            .id(reference)
            .environment(\.pageScroller, pageScroller)
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
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
        .padding(.horizontal, 4)
    }

    private var prSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            listTitle
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)

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
        HStack(alignment: .center, spacing: 10) {
            listTitleIcon
                .foregroundStyle(monitor.selectedTab.tint)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(monitor.selectedTab.title)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                if let count = listCount, count > 0 {
                    Text(String(count))
                        .font(.system(size: 20, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// GitHub's pull request mark for My PRs, drawn to match the design; SF Symbols for the other tabs.
    @ViewBuilder
    private var listTitleIcon: some View {
        if monitor.selectedTab == .open {
            PullRequestGlyph()
                .stroke(style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: monitor.selectedTab.systemImage)
                .font(.system(size: 21, weight: .semibold))
                .frame(width: 24, height: 24)
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
                                mergeMethod: monitor.mergeMethod(for: pr),
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
                                mergeMethodMenu(for: pr)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                openRowIDs = monitor.prRows.map(\.id)
                if selectedPRID == nil {
                    selectedPRID = monitor.prRows.first?.id
                }
            }
            .onChange(of: monitor.prRows.map { $0.id }) { newIDs in
                selectedPRID = ListNavigation.selection(after: selectedPRID, oldIDs: openRowIDs, newIDs: newIDs)
                openRowIDs = newIDs
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
                    // A failed refresh keeps the last list, so say why it may be out of date.
                    if let error = monitor.lastReviewRequestsError {
                        errorNote(error, hint: nil)
                    }
                    reviewRequestsList
                }
            }
        }
        .onAppear {
            reviewRowIDs = monitor.reviewRequests.rows.map(\.id)
            if selectedReviewID == nil {
                selectedReviewID = monitor.reviewRequests.rows.first?.id
            }
        }
        .onChange(of: monitor.reviewRequests.rows.map { $0.id }) { newIDs in
            selectedReviewID = ListNavigation.selection(after: selectedReviewID, oldIDs: reviewRowIDs, newIDs: newIDs)
            reviewRowIDs = newIDs
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
        // A small accent heading over each group, like a sidebar section heading.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(group.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(String(rows.count))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, group == ReviewRequestGroup.allCases.first ? 4 : 16)
        .padding(.bottom, 2)

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
                .fill(Theme.red.opacity(0.1))
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
                    .controlChrome(in: Capsule())
                    .contentShape(Capsule())
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
                    .controlChrome(in: Capsule())
                    .contentShape(Capsule())
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
        return PrimaryAction(title: state.title(mergeMethod: monitor.mergeMethod(for: pr)), isEnabled: state.isClickable) {
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

    /// Picks how Merge and Enable auto-merge merge this repository's pull requests. Checked items come from the picker.
    @ViewBuilder
    private func mergeMethodMenu(for pr: PullRequestRow) -> some View {
        if pr.mergeMethods.allowed.count > 1 {
            Divider()
            Picker("Merge Method", selection: Binding(get: { monitor.mergeMethod(for: pr) },
                                                      set: { monitor.chooseMergeMethod($0, for: pr.repoFullName) })) {
                ForEach(pr.mergeMethods.allowed) { method in
                    Text(method.title).tag(method)
                }
            }
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

/// The My PRs / To Review / History switcher over the list. Its segments share the row's width,
/// so its edges line up with the rows under it.
struct PullRequestTabPicker: View {
    @Binding var selection: PullRequestTab

    static let segments = PullRequestTab.allCases.map {
        GlassSegmentedControl<PullRequestTab>.Segment(value: $0, title: $0.title)
    }

    var body: some View {
        GlassSegmentedControl(selection: $selection, segments: Self.segments, fillsWidth: true)
    }
}


private extension PullRequestTab {
    /// My PRs draws ``PullRequestGlyph`` instead; this is its stand-in.
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
