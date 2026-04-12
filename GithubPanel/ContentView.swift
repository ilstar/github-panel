import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var monitor: PRMonitor
    @State private var tokenInput: String = ""
    @State private var isSaving = false
    @State private var now = Date()
    @State private var selectedPRID: String?
    @State private var mergeInFlight: Set<String> = []
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
                                        now: now,
                                        isMerging: mergeInFlight.contains(pr.id),
                                        onMerge: {
                                            merge(pr: pr)
                                        }
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
            .frame(width: 110, alignment: .trailing)
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

    private func merge(pr: PullRequestRow) {
        if mergeInFlight.contains(pr.id) { return }
        mergeInFlight.insert(pr.id)
        Task {
            await monitor.requestMerge(for: pr)
            await MainActor.run {
                mergeInFlight.remove(pr.id)
            }
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
    let isMerging: Bool
    let onMerge: () -> Void

    @State private var isHovering = false
    @State private var isMergeButtonHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 6) {
                Text(pr.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .help(pr.title)

                Text("\(pr.repoFullName)#\(String(pr.number)) · \(pr.status.descriptionText)")
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

            mergeButton
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardFill)
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

    private var isReady: Bool {
        pr.status == .success && !pr.isDraft
    }

    private var mergeButtonState: MergeButtonState {
        if isMerging {
            return .working
        }
        if pr.status == .failure || pr.status == .error {
            return .checksFailed
        }
        if pr.isInMergeQueue {
            return .queued
        }
        if isReady {
            return .merge
        }
        if pr.isAutoMergeEnabled {
            return .disableAutoMerge
        }
        if pr.canEnableAutoMerge {
            return .enableAutoMerge
        }
        return .waitingForChecks
    }

    private var mergeButton: some View {
        Button(action: handleMergeButtonClick) {
            HStack(spacing: 6) {
                if mergeButtonState == .working {
                    ProgressView()
                        .controlSize(.small)
                        .tint(mergeProgressTint)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: mergeIconName)
                        .font(.caption.weight(.bold))
                        .frame(width: 12)
                }

                Text(mergeButtonTitle)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            .frame(width: 168, height: 30)
            .foregroundStyle(mergeForeground)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(mergeFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(mergeStroke, lineWidth: 1)
            )
            .shadow(color: mergeShadow, radius: isMerging ? 0 : 4, x: 0, y: 1)
            .offset(y: mergeButtonOffset)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(mergeButtonState == .working)
        .opacity(mergeButtonState == .working ? 0.75 : 1)
        .animation(.easeInOut(duration: 0.12), value: isMergeButtonHovering)
        .onHover { hovering in
            isMergeButtonHovering = hovering && mergeButtonState.hasHoverEffect
        }
    }

    private func handleMergeButtonClick() {
        guard mergeButtonState.isClickable else { return }
        onMerge()
    }

    private var mergeButtonTitle: String {
        mergeButtonState.title
    }

    private var mergeIconName: String {
        mergeButtonState.iconName
    }

    private var mergeFill: Color {
        switch mergeButtonState {
        case .disableAutoMerge:
            return isMergeButtonHovering
                ? Color(red: 1.0, green: 0.95, blue: 0.94)
                : Color(red: 1.0, green: 0.98, blue: 0.97)
        case .merge:
            return isMergeButtonHovering
                ? Color(red: 0.16, green: 0.56, blue: 0.29)
                : Color(red: 0.13, green: 0.49, blue: 0.25)
        case .enableAutoMerge:
            return isMergeButtonHovering
                ? Color(red: 0.91, green: 0.96, blue: 1.0)
                : Color(red: 0.95, green: 0.98, blue: 1.0)
        case .queued:
            return isMergeButtonHovering
                ? Color(red: 0.94, green: 0.99, blue: 0.96)
                : Color.white
        case .checksFailed:
            return Color(red: 1.0, green: 0.96, blue: 0.96)
        case .waitingForChecks, .working:
            return Color.white
        }
    }

    private var mergeForeground: Color {
        switch mergeButtonState {
        case .merge:
            return Color.white
        case .disableAutoMerge:
            return Color(red: 0.58, green: 0.18, blue: 0.14)
        case .enableAutoMerge:
            return Color(red: 0.14, green: 0.36, blue: 0.62)
        case .queued:
            return Color(red: 0.10, green: 0.43, blue: 0.24)
        case .checksFailed:
            return Color(red: 0.72, green: 0.16, blue: 0.16)
        case .waitingForChecks, .working:
            return Color.secondary
        }
    }

    private var mergeStroke: Color {
        switch mergeButtonState {
        case .disableAutoMerge:
            return Color(red: 0.78, green: 0.34, blue: 0.28).opacity(isMergeButtonHovering ? 0.64 : 0.38)
        case .merge:
            return Color(red: 0.06, green: 0.38, blue: 0.16).opacity(isMergeButtonHovering ? 0.62 : 0.45)
        case .enableAutoMerge:
            return Color(red: 0.50, green: 0.68, blue: 0.86).opacity(isMergeButtonHovering ? 0.68 : 0.45)
        case .queued:
            return Color(red: 0.30, green: 0.63, blue: 0.42).opacity(isMergeButtonHovering ? 0.55 : 0.32)
        case .checksFailed:
            return Color(red: 0.78, green: 0.22, blue: 0.20).opacity(0.34)
        case .waitingForChecks, .working:
            return Color.black.opacity(0.12)
        }
    }

    private var mergeShadow: Color {
        switch mergeButtonState {
        case .disableAutoMerge:
            return Color.red.opacity(isMergeButtonHovering ? 0.13 : 0.06)
        case .merge:
            return Color.green.opacity(isMergeButtonHovering ? 0.26 : 0.18)
        case .enableAutoMerge:
            return Color.black.opacity(isMergeButtonHovering ? 0.10 : 0.06)
        case .queued:
            return Color.green.opacity(isMergeButtonHovering ? 0.14 : 0.07)
        case .checksFailed, .waitingForChecks, .working:
            return Color.black.opacity(0.04)
        }
    }

    private var mergeProgressTint: Color {
        isReady ? Color.white : mergeForeground
    }

    private var mergeButtonOffset: CGFloat {
        isMergeButtonHovering ? -1 : 0
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

    private var cardFill: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(
                LinearGradient(colors: [
                    Color(red: 0.93, green: 0.96, blue: 1.0),
                    Color(red: 0.98, green: 0.99, blue: 1.0)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        return AnyShapeStyle(Color.white.opacity(isHovering ? 0.95 : 0.9))
    }
}

private enum MergeButtonState {
    case merge
    case enableAutoMerge
    case disableAutoMerge
    case queued
    case checksFailed
    case waitingForChecks
    case working

    var title: String {
        switch self {
        case .merge:
            return "Merge"
        case .enableAutoMerge:
            return "Enable auto-merge"
        case .disableAutoMerge:
            return "Disable auto-merge"
        case .queued:
            return "Queued"
        case .checksFailed:
            return "Checks failed"
        case .waitingForChecks:
            return "Waiting for checks"
        case .working:
            return "Working..."
        }
    }

    var iconName: String {
        switch self {
        case .merge:
            return "checkmark"
        case .enableAutoMerge:
            return "bolt"
        case .disableAutoMerge:
            return "xmark"
        case .queued:
            return "checkmark.circle"
        case .checksFailed:
            return "xmark"
        case .waitingForChecks:
            return "clock"
        case .working:
            return "clock"
        }
    }

    var isClickable: Bool {
        switch self {
        case .merge, .enableAutoMerge, .disableAutoMerge:
            return true
        case .queued, .checksFailed, .waitingForChecks, .working:
            return false
        }
    }

    var hasHoverEffect: Bool {
        switch self {
        case .merge, .enableAutoMerge, .disableAutoMerge, .queued:
            return true
        case .checksFailed, .waitingForChecks, .working:
            return false
        }
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

    @State private var spinStart = Date()
    @State private var stopAtCycle: Double?
    private let spinDuration = 1.6

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
            HStack(spacing: 6) {
                TimelineView(.animation) { context in
                    Image(systemName: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .rotationEffect(.degrees(rotationAngle(at: context.date)))
                        .opacity(isLoading || stopAtCycle != nil ? 1 : 1)
                }
                Text("Refresh")
                    .font(.subheadline.weight(.semibold))
                    .padding(.trailing, 2)
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
        .onAppear {
            spinStart = Date()
        }
        .onChange(of: isLoading) { loading in
            let now = Date()
            if loading {
                spinStart = now
                stopAtCycle = nil
            } else {
                let cycles = max(0, now.timeIntervalSince(spinStart) / spinDuration)
                stopAtCycle = ceil(cycles)
            }
        }
    }

    private func rotationAngle(at date: Date) -> Double {
        guard isLoading || stopAtCycle != nil else {
            return 0
        }
        let elapsed = max(0, date.timeIntervalSince(spinStart))
        let cycles = elapsed / spinDuration
        if let stopAtCycle, cycles >= stopAtCycle {
            return 0
        }
        let fraction = cycles.truncatingRemainder(dividingBy: 1)
        return fraction * 360
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
