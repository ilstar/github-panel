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
        .frame(minWidth: 1000, minHeight: 500)
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

    private var listPane: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 18) {
                if monitor.isUsingMockData {
                    mockDataBanner
                }

                if !monitor.hasToken {
                    tokenCallout

                }

                prSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let reference = selectedReference {
            PullRequestDetailView(viewModel: PullRequestDetailViewModel(reference: reference, monitor: monitor))
            .id(reference)
            .environment(\.pageScroller, pageScroller)
        } else {
            Text(monitor.hasToken ? "Select a pull request" : "Add a GitHub token to begin.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
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
        Text("Mock GitHub PRs")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.95, green: 0.98, blue: 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(red: 0.50, green: 0.68, blue: 0.86).opacity(0.45), lineWidth: 1)
            )
            .foregroundStyle(Color(red: 0.14, green: 0.36, blue: 0.62))
    }

    private var tokenCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub Token")
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
                .disabled(isSaving || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.7))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var prSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                PullRequestTabPicker(selection: $monitor.selectedTab)

                Spacer()
                refreshPill
                    .fixedSize()
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

    private var openPullRequestsSection: some View {
        Group {
            if let error = monitor.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("Common fixes: ensure your token has `repo` (private) or `public_repo` scopes, and authorize SSO for org repos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if monitor.hasToken {
                openPullRequestsList
            } else {
                Text("Add a GitHub token to begin.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var openPullRequestsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
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
                .padding(.top, 6)
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
            } else {
                Text("Add a GitHub token to begin.")
                    .foregroundStyle(.secondary)
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
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(ReviewRequestGroup.allCases) { group in
                        reviewRequestGroup(group)
                    }
                }
                .padding(.top, 6)
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
        HStack(spacing: 6) {
            Text(group.title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            Text(String(rows.count))
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.14)))
        }
        .padding(.leading, 4)
        .padding(.top, group == ReviewRequestGroup.allCases.first ? 0 : 12)

        if rows.isEmpty {
            Text(group.emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
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
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if monitor.hasToken {
                VStack(spacing: 10) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
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
                            .padding(.top, 6)
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
            } else {
                Text("Add a GitHub token to begin.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lastUpdatedView: some View {
        Text("Updated \(lastUpdatedText)")
            .font(.caption)
            .foregroundStyle(.secondary)
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
        HStack(spacing: 8) {
            Button {
                Task { await monitor.loadPreviousHistoryPage() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!monitor.canLoadPreviousHistoryPage)
            .help("Previous page")

            Text(monitor.historyRangeText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 86)

            Button {
                Task { await monitor.loadNextHistoryPage() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!monitor.canLoadNextHistoryPage)
            .help("Next page")

            Spacer()
        }
    }

    private var emptyStateSpacer: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 220)
            .accessibilityHidden(true)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [
                Color.white,
                Color(red: 0.96, green: 0.96, blue: 0.97)
            ], startPoint: .top, endPoint: .bottom)

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
