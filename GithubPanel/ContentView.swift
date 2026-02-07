import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitor: PRMonitor
    @State private var tokenInput: String = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GitHub Panel")
                .font(.title)
                .bold()

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

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Open Pull Requests")
                    .font(.headline)

                if let error = monitor.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text("Common fixes: ensure your token has `repo` (private) or `public_repo` scopes, and authorize SSO for org repos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if monitor.isLoading {
                    Text("Loading...")
                        .foregroundStyle(.secondary)
                } else if monitor.hasToken {
                    if !monitor.prRows.isEmpty {
                        List(monitor.prRows) { pr in
                            Link(destination: pr.htmlURL) {
                                HStack(alignment: .top, spacing: 10) {
                                    Text(pr.status.emoji)
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pr.title)
                                            .font(.subheadline)
                                            .lineLimit(2)
                                        Text("\(pr.repoFullName)#\(pr.number) · \(pr.status.descriptionText)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .frame(height: 200)
                    } else {
                        Text("No open pull requests found for your account.")
                            .foregroundStyle(.secondary)
                        Text("Only PRs authored by your GitHub user are shown.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Add a GitHub token to begin.")
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 300)
        .onAppear {
            monitor.start()
        }
    }

    private func saveToken() {
        isSaving = true
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        monitor.saveToken(token)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isSaving = false
        }
    }

    private func clearToken() {
        tokenInput = ""
        monitor.clearToken()
    }
}
