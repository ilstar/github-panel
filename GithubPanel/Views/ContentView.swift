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
    @State private var selectedHistoryID: String?
    @State private var mergeInFlight: Set<String> = []
    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 420, idealWidth: 460, maxWidth: 640)
            detailPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 500)
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
            PullRequestDetailView(viewModel: PullRequestDetailViewModel(reference: reference) { [monitor] reference in
                try await monitor.fetchPullRequestDetail(reference)
            })
            .id(reference)
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
                                       historyRows: monitor.historyRows,
                                       selectedOpenID: selectedPRID,
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
                Text("Pull Requests")
                    .font(.title3.weight(.semibold))

                Picker("", selection: $monitor.selectedTab) {
                    ForEach(PullRequestTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .labelsHidden()

                Spacer()
                refreshPill
            }
            .onChange(of: monitor.selectedTab) { tab in
                if tab == .history {
                    monitor.loadHistoryIfNeeded()
                }
            }

            if monitor.selectedTab == .open {
                openPullRequestsSection
            } else {
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
                            openOnGitHubIfCommandHeld(pr.htmlURL)
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
        .background(
            KeyEventHandlingView { event in
                handleKeyEvent(event)
            }
            .frame(width: 0, height: 0)
        )
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
                                                openOnGitHubIfCommandHeld(pr.htmlURL)
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
        if monitor.selectedTab == .history {
            guard let lastHistoryRefreshAt = monitor.lastHistoryRefreshAt else {
                return "Never"
            }
            return relativeFormatter.localizedString(for: lastHistoryRefreshAt, relativeTo: now)
        }
        return monitor.lastRefreshText(relativeTo: now)
    }

    private var refreshPill: some View {
        RefreshPill(isLoading: monitor.selectedTab == .history ? monitor.isHistoryLoading : monitor.isLoading,
                    isEnabled: refreshIsEnabled,
                    lastUpdatedView: lastUpdatedView) {
            refreshSelectedTab()
        }
    }

    private var refreshIsEnabled: Bool {
        guard monitor.hasToken else { return false }
        return monitor.selectedTab == .history ? !monitor.isHistoryLoading : !monitor.isLoading
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
        if monitor.selectedTab == .history {
            Task { await monitor.refreshCurrentHistoryPage() }
        } else {
            Task { await monitor.refreshNow() }
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: // down arrow
            moveSelection(delta: 1)
            return true
        case 126: // up arrow
            moveSelection(delta: -1)
            return true
        case 36, 76: // return, enter
            openSelectedPR()
            return true
        default:
            return false
        }
    }

    private func moveSelection(delta: Int) {
        guard !monitor.prRows.isEmpty else { return }
        let ids = monitor.prRows.map { $0.id }
        let currentIndex = selectedPRID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), ids.count - 1)
        selectedPRID = ids[nextIndex]
    }

    private func openSelectedPR() {
        guard let id = selectedPRID,
              let pr = monitor.prRows.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(pr.htmlURL)
    }

    /// Row clicks show the PR on the right; ⌘-click also opens it on GitHub.
    private func openOnGitHubIfCommandHeld(_ htmlURL: URL) {
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
