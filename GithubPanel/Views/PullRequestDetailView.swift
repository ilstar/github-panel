import SwiftUI
import AppKit

enum PullRequestDetailTab: String, CaseIterable, Identifiable {
    case conversation
    case files

    var id: String { rawValue }
}

struct PullRequestDetailView: View {
    @StateObject private var viewModel: PullRequestDetailViewModel
    @State private var selectedTab: PullRequestDetailTab = .conversation

    init(viewModel: @autoclosure @escaping () -> PullRequestDetailViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let content = viewModel.content {
                PullRequestDetailHeader(detail: content.detail,
                                        isLoading: viewModel.isLoading,
                                        onRefresh: reload)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                if let error = viewModel.errorMessage {
                    errorText(error)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }

                Picker("", selection: $selectedTab) {
                    Text("Conversation").tag(PullRequestDetailTab.conversation)
                    Text("Files changed \(content.files.count)").tag(PullRequestDetailTab.files)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                Divider()

                switch selectedTab {
                case .conversation:
                    PullRequestConversationView(detail: content.detail)
                case .files:
                    PullRequestFilesView(files: content.files,
                                         diffLines: viewModel.diffLines,
                                         filesURL: content.detail.htmlURL.appendingPathComponent("files"))
                }
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    errorText(error)
                    Button("Try Again", action: reload)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(navigationTitle)
        .task {
            await viewModel.load()
        }
    }

    private var navigationTitle: String {
        let reference = viewModel.reference
        guard let title = viewModel.content?.detail.title else { return reference.id }
        return "\(title) · \(reference.id)"
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }

    private func reload() {
        Task { await viewModel.load() }
    }
}

struct PullRequestDetailHeader: View {
    let detail: PullRequestDetail
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(detail.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text("#\(String(detail.reference.number))")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help("Reload")

                Button("Open on GitHub") {
                    NSWorkspace.shared.open(detail.htmlURL)
                }
            }

            HStack(spacing: 8) {
                PullRequestStateBadge(state: detail.state)

                Text(summaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 12)

                Text("+\(detail.additions)")
                    .foregroundStyle(DiffColors.additionText)
                Text("−\(detail.deletions)")
                    .foregroundStyle(DiffColors.deletionText)
            }
            .font(.callout.monospacedDigit())
        }
    }

    private var summaryText: String {
        let commits = detail.commits == 1 ? "1 commit" : "\(detail.commits) commits"
        return "\(detail.authorLogin) wants to merge \(commits) into \(detail.baseRef) from \(detail.headRef) · \(detail.reference.repoFullName)"
    }
}

struct PullRequestStateBadge: View {
    let state: PullRequestDetail.State

    var body: some View {
        Label(title, systemImage: iconName)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color))
            .foregroundStyle(.white)
    }

    private var title: String {
        switch state {
        case .open: return "Open"
        case .draft: return "Draft"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    private var iconName: String {
        switch state {
        case .open, .draft: return "arrow.triangle.pull"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }

    private var color: Color {
        switch state {
        case .open: return Color(red: 0.12, green: 0.53, blue: 0.24)
        case .draft: return Color(red: 0.40, green: 0.43, blue: 0.47)
        case .merged: return Color(red: 0.51, green: 0.31, blue: 0.85)
        case .closed: return Color(red: 0.81, green: 0.13, blue: 0.18)
        }
    }
}

struct PullRequestConversationView: View {
    let detail: PullRequestDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(detail.authorLogin) opened this pull request \(detail.createdAt.formatted(.relative(presentation: .named)))")
                    .font(.callout.weight(.semibold))

                Group {
                    if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description provided.")
                            .italic()
                            .foregroundStyle(.secondary)
                    } else {
                        Text(Self.markdown(detail.body))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

enum DiffColors {
    static let additionText = Color(red: 0.10, green: 0.50, blue: 0.22)
    static let deletionText = Color(red: 0.81, green: 0.13, blue: 0.18)
    static let additionBackground = Color.green.opacity(0.14)
    static let deletionBackground = Color.red.opacity(0.12)
    static let hunkBackground = Color.blue.opacity(0.08)
}
