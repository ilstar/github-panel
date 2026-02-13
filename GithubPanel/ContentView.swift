import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var monitor: PRMonitor
    @State private var tokenInput: String = ""
    @State private var isSaving = false
    @State private var now = Date()
    @State private var selectedPRID: String?
    private let minuteTicker = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 18) {
                if !monitor.hasToken {
                    tokenCallout
                }

                prSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 420, minHeight: 300)
        .onAppear {
            monitor.start()
        }
        .onReceive(minuteTicker) { tick in
            now = tick
        }
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
            HStack(alignment: .firstTextBaseline) {
                Text("Open Pull Requests")
                    .font(.title3.weight(.semibold))
                Spacer()
                refreshPill
            }

            if let error = monitor.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                Text("Common fixes: ensure your token has `repo` (private) or `public_repo` scopes, and authorize SSO for org repos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if monitor.hasToken {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if monitor.prRows.isEmpty {
                                emptyState
                            } else {
                                ForEach(monitor.prRows) { pr in
                                    PRRow(
                                        pr: pr,
                                        isSelected: selectedPRID == pr.id,
                                        relativeFormatter: relativeFormatter,
                                        now: now
                                    )
                                    .id(pr.id)
                                    .onTapGesture {
                                        selectedPRID = pr.id
                                        NSWorkspace.shared.open(pr.htmlURL)
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
                    .onChange(of: monitor.lastRefreshAt) { _ in
                        guard let first = monitor.prRows.first else { return }
                        selectedPRID = first.id
                        withAnimation {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                }
            } else {
                Text("Add a GitHub token to begin.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lastUpdatedView: some View {
        Text("Updated \(monitor.lastRefreshText(relativeTo: now))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var refreshPill: some View {
        RefreshPill(isLoading: monitor.isLoading,
                    isEnabled: monitor.hasToken && !monitor.isLoading,
                    lastUpdatedView: lastUpdatedView) {
            monitor.start()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No open pull requests found for your account.")
                .foregroundStyle(.secondary)
            Text("Only PRs authored by your GitHub user are shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.8))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var background: some View {
        LinearGradient(colors: [
            Color.white,
            Color(red: 0.96, green: 0.96, blue: 0.97)
        ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
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
}

private struct PRRow: View {
    let pr: PullRequestRow
    let isSelected: Bool
    let relativeFormatter: RelativeDateTimeFormatter
    let now: Date

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.secondary.opacity(isSelected ? 0.7 : 0.0))
                .frame(width: 6, height: 6)
                .padding(.top, 7)
                .padding(.leading, 4)

            statusIcon

            VStack(alignment: .leading, spacing: 6) {
                Text(pr.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                Text("\(pr.repoFullName)#\(pr.number) · \(pr.status.descriptionText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if pr.isDraft {
                        DraftBadge()
                    }

                    Text("Updated \(relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: now))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.95 : 0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.04), radius: 8, x: 0, y: 2)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var statusIcon: some View {
        Group {
            switch pr.status {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure, .error:
                Image(systemName: "xmark.octagon.fill")
                    .symbolRenderingMode(.multicolor)
            case .pending:
                Image(systemName: "clock.fill")
                    .foregroundStyle(.secondary)
            case .unknown:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.title)
        .frame(width: 30)
    }
}

private struct DraftBadge: View {
    var body: some View {
        Text("DRAFT")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.gray.opacity(0.2))
            )
            .foregroundStyle(.secondary)
    }
}

private struct RefreshPill: View {
    let isLoading: Bool
    let isEnabled: Bool
    let lastUpdatedView: AnyView
    let action: () -> Void

    init(isLoading: Bool,
         isEnabled: Bool,
         lastUpdatedView: some View,
         action: @escaping () -> Void) {
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.lastUpdatedView = AnyView(lastUpdatedView)
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                Text("Refresh")
                    .font(.subheadline.weight(.semibold))
                lastUpdatedView
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct KeyEventHandlingView: NSViewRepresentable {
    var handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.handler = handler
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyView else { return }
        view.handler = handler
    }

    private final class KeyView: NSView {
        var handler: ((NSEvent) -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if handler?(event) == true {
                return
            }
            super.keyDown(with: event)
        }
    }
}
