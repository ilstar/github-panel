import SwiftUI
import UniformTypeIdentifiers
import KeyboardShortcuts

struct SettingsView: View {
    @EnvironmentObject private var monitor: PRMonitor
    @State private var tokenInput: String = ""
    @State private var isSaving = false
    @AppStorage(AppAppearance.defaultsKey, store: AppDefaults.store) private var appearance: AppAppearance = .system

    @AppStorage(DetailPaneMode.defaultsKey, store: AppDefaults.store) private var detailPaneMode: DetailPaneMode = .native
    @AppStorage(PullRequestTextSize.defaultsKey, store: AppDefaults.store) private var prTextSize = PullRequestTextSize.defaultSize

    var body: some View {
        Form {
            tokenSection
            appearanceSection
            WebExtensionsSection()
            notificationsSection
            refreshSection
            hooksSection
            shortcutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 640)
    }

    private var tokenSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Create a personal access token in GitHub and paste it here.")
                    .foregroundStyle(.secondary)
                Link("https://github.com/settings/tokens", destination: URL(string: "https://github.com/settings/tokens")!)
                Text("Permissions needed: `repo` for private repos, or `public_repo` for public-only.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            SecureField("Token", text: $tokenInput, prompt: Text("ghp_..."))

            HStack {
                if monitor.hasToken {
                    Label("Token saved in Keychain", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        clearToken()
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                Button(isSaving ? "Saving..." : "Save Token") {
                    saveToken()
                }
                .disabled(isSaving || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("GitHub Token")
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { newValue in
                newValue.apply()
            }
            Picker("Pull request pane", selection: $detailPaneMode) {
                ForEach(DetailPaneMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Text("GitHub.com shows the pull request's page from github.com. Sign in to GitHub in the pane the first time.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper("PR text size: \(PullRequestTextSize.clamped(prTextSize)) pt", value: Binding(
                get: { PullRequestTextSize.clamped(prTextSize) },
                set: { prTextSize = $0 }
            ), in: PullRequestTextSize.range)
            Text("Adjusts text in PR descriptions, comments, file trees, and diffs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset PR Text Size") {
                prTextSize = PullRequestTextSize.defaultSize
            }
            .disabled(prTextSize == PullRequestTextSize.defaultSize)
        } header: {
            Text("Appearance")
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("Check results", isOn: $monitor.notifyCheckResults)
            Toggle("Approvals on my pull requests", isOn: $monitor.notifyApprovals)
            Toggle("Changes requested on my pull requests", isOn: $monitor.notifyChangesRequested)
            Toggle("Review requests from me", isOn: $monitor.notifyReviewsFromMe)
            Toggle("Review requests from my teams", isOn: $monitor.notifyReviewsFromMyTeams)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Choose which events send macOS notifications. Check results are sent when pending checks finish. Requests sent directly to you use the personal setting, even if your team is also requested.")
        }
    }

    private var refreshSection: some View {
        Section {
            Picker("Auto refresh", selection: $monitor.refreshInterval) {
                Text("1 min").tag(60.0)
                Text("5 mins").tag(300.0)
                Text("10 mins").tag(600.0)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Auto Refresh")
        }
    }

    private var shortcutSection: some View {
        Section {
            KeyboardShortcuts.Recorder("Show/Hide App", name: .toggleApp)
        } header: {
            Text("Shortcut")
        }
    }

    private var hooksSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("All Succeeded")
                    .font(.callout.weight(.medium))
                scriptEditor(text: $monitor.allSucceededHookScript)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Any Failures")
                    .font(.callout.weight(.medium))
                scriptEditor(text: $monitor.anyFailuresHookScript)
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hooks")
                Text("Scripts run after a PR moves from pending to a completed check state.")
                    .font(.callout)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Environment: GITHUB_PANEL_PR_NUMBER, GITHUB_PANEL_PR_ID, GITHUB_PANEL_PR_NODE_ID, GITHUB_PANEL_REPO_FULL_NAME, GITHUB_PANEL_PR_URL, GITHUB_PANEL_PR_STATUS, GITHUB_PANEL_HOOK_SCENARIO, GITHUB_PANEL_PR_HEAD_SHA.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scriptEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 82)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline)
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

    private func clearToken() {
        tokenInput = ""
        monitor.clearToken()
    }
}

/// The extensions that run in the GitHub.com pane: add, turn on or off, open options, remove.
private struct WebExtensionsSection: View {
    @ObservedObject private var extensions = WebExtensions.shared
    @State private var installError: String?
    @State private var isInstalling = false

    var body: some View {
        Section {
            if WebExtensions.isSupported {
                if extensions.installed.isEmpty {
                    Text("No extensions added.")
                        .foregroundStyle(.secondary)
                }
                ForEach(extensions.installed) { item in
                    row(item)
                }
                HStack {
                    if let installError {
                        Text(installError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(isInstalling ? "Adding…" : "Add Extension…", action: chooseExtension)
                        .disabled(isInstalling)
                }
            } else {
                Text("Extensions need macOS 15.4 or later.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("GitHub.com Extensions")
        } footer: {
            Text("Add a Chrome extension as an unpacked folder, a .zip, or a .crx file. Extensions run in the GitHub.com pane and get the permissions they ask for. Features only Chrome has, such as side panels, don't work.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ item: InstalledWebExtension) -> some View {
        let status = extensions.statuses[item.id]
        return HStack(spacing: 10) {
            Group {
                if let icon = status?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if let version = item.version {
                    Text("Version \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = status?.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let warning = status?.warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if item.isEnabled, status?.hasOptionsPage == true {
                Button("Options") { extensions.openOptions(for: item.id) }
                    .buttonStyle(.borderless)
            }
            Toggle("Enabled", isOn: Binding(
                get: { item.isEnabled },
                set: { newValue in Task { await extensions.setEnabled(newValue, for: item.id) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Button {
                extensions.remove(id: item.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(item.name)")
            .accessibilityLabel("Remove \(item.name)")
        }
    }

    private func chooseExtension() {
        let panel = NSOpenPanel()
        panel.message = "Choose an unpacked extension folder, a .zip, or a .crx file."
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip, UTType(filenameExtension: "crx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isInstalling = true
        installError = nil
        Task {
            do {
                try await extensions.install(from: url)
            } catch {
                installError = error.localizedDescription
            }
            isInstalling = false
        }
    }
}
