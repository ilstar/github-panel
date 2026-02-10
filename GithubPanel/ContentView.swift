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
        VStack(alignment: .leading, spacing: 16) {
            Text("GitHub Panel")
                .font(.title)
                .bold()

            if !monitor.hasToken {
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

                Divider()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Open Pull Requests")
                    .font(.headline)

                HStack(spacing: 12) {
                    Button("Refresh") {
                        monitor.start()
                    }
                    .disabled(!monitor.hasToken || monitor.isLoading)

                    HStack(spacing: 6) {
                        if monitor.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Updated \(monitor.lastRefreshText(relativeTo: now))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                    List(monitor.prRows) { pr in
                        Link(destination: pr.htmlURL) {
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(Color.secondary.opacity(selectedPRID == pr.id ? 0.7 : 0.0))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 6)
                                    .padding(.leading, 4)
                                Text(pr.status.emoji)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pr.title)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                    Text("\(pr.repoFullName)#\(pr.number) · \(pr.status.descriptionText)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if pr.isDraft {
                                        Text("Draft")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    Text("Updated \(relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: now))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.leading, -12)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .listStyle(.plain)
                    .padding(.leading, -4)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if monitor.prRows.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No open pull requests found for your account.")
                                    .foregroundStyle(.secondary)
                                Text("Only PRs authored by your GitHub user are shown.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 6)
                        }
                    }
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
                } else {
                    Text("Add a GitHub token to begin.")
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(minWidth: 420, minHeight: 300)
        .onAppear {
            monitor.start()
        }
        .onReceive(minuteTicker) { tick in
            now = tick
        }
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
