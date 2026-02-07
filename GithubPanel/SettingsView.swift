import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var monitor: PRMonitor
    @State private var tokenInput: String = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2)
                .bold()

            tokenSection

            Divider()

            refreshSection

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 260)
    }

    private var tokenSection: some View {
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

                if monitor.hasToken {
                    Text("Token saved in Keychain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear") {
                        clearToken()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto Refresh")
                .font(.headline)

            Picker("Auto refresh", selection: $monitor.refreshInterval) {
                Text("1 min").tag(60.0)
                Text("5 mins").tag(300.0)
                Text("10 mins").tag(600.0)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
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
