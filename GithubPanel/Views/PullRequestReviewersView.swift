import SwiftUI

/// The Reviewers section of GitHub's pull request sidebar: each requested or reviewing user and team with
/// their status on the right, then the overall verdict.
struct PullRequestReviewersView: View {
    let reviewers: PullRequestReviewers
    /// Set when the viewer may request reviews, which shows the gear that opens the picker.
    var actions: ReviewerRequestActions?

    @State private var isPicking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Reviewers")
                    .prFont(.callout, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let actions {
                    Button {
                        isPicking = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isPicking ? Color.accentColor : .secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Request reviews")
                    .accessibilityLabel("Request reviews")
                    .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                        ReviewerPicker(reviewers: reviewers, actions: actions)
                    }
                }
            }

            if reviewers.reviewers.isEmpty {
                Text("No reviews")
                    .prFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(reviewers.reviewers) { reviewer in
                        PullRequestReviewerRow(reviewer: reviewer,
                                               isReRequesting: actions?.inFlight.contains(reviewer.id) == true,
                                               onReRequest: actions.map { actions in
                                                   { actions.setRequested(reviewer.name, reviewer.kind, true) }
                                               })
                    }
                }
            }

            if !reviewers.reviewers.isEmpty || reviewers.decision != nil {
                verdict
                    .padding(.top, 2)
            }
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // GitHub separates sidebar sections with a hairline.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    private var verdict: some View {
        let summary = reviewers.summary
        return VStack(alignment: .leading, spacing: 2) {
            Text(summary.title)
                .prFont(.caption1, weight: .semibold)
                .foregroundStyle(summary.tone?.color ?? .secondary)
            if let detail = summary.detail {
                Text(detail)
                    .prFont(.caption1)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PullRequestReviewerRow: View {
    let reviewer: PullRequestReviewer
    var isReRequesting = false
    /// Set when the viewer may request reviews; shows GitHub's re-request button next to a finished review.
    var onReRequest: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(reviewer.name)
                        .prFont(.callout, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if reviewer.isCodeOwner {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help("Requested as a code owner")
                    }
                }
                if !reviewer.onBehalfOf.isEmpty {
                    Text("for \(reviewer.onBehalfOf.joined(separator: ", "))")
                        .prFont(.caption1)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            if isReRequesting {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else if let onReRequest, reviewer.canReRequest {
                Button(action: onReRequest) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Re-request review")
                .accessibilityLabel("Re-request review from \(reviewer.name)")
            }
            statusIcon
                .accessibilityLabel(reviewer.helpText)
        }
        .help(reviewer.helpText)
    }

    @ViewBuilder
    private var avatar: some View {
        switch reviewer.kind {
        case .user:
            AvatarView(login: reviewer.name, size: 20)
        case .team:
            Image(systemName: "person.2.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.secondary.opacity(0.14)))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch reviewer.state {
        case .pending:
            Circle()
                .fill(Theme.amber)
                .frame(width: 8, height: 8)
                .frame(width: 16, height: 16)
        case .approved:
            icon("checkmark", color: Theme.green)
        case .changesRequested:
            icon("plusminus.circle", color: Theme.red)
        case .commented:
            icon("text.bubble", color: .secondary)
        case .dismissed:
            icon("xmark", color: .secondary)
        }
    }

    private func icon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
    }
}

/// What the reviewer picker needs from the detail window.
struct ReviewerRequestActions {
    /// Reviewers whose request is being added or removed, by `PullRequestReviewer.id`.
    var inFlight: Set<String> = []
    let loadCandidates: (String) async throws -> [ReviewerCandidate]
    /// Requests a review from a user or team, or removes their request.
    let setRequested: (String, PullRequestReviewer.Kind, Bool) -> Void
}

/// GitHub's "Request up to 15 reviewers" menu: a search field over suggested reviewers, people and teams.
/// Clicking one requests a review, or removes the request when it is already checked.
struct ReviewerPicker: View {
    let reviewers: PullRequestReviewers
    let actions: ReviewerRequestActions

    @State private var query = ""
    @State private var candidates: [ReviewerCandidate]?
    @State private var error: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Request up to 15 reviewers")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            TextField("Type or choose a user", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.vertical, 4)
            }
            .frame(height: 260)
        }
        .frame(width: 300)
        .onAppear { isSearchFocused = true }
        // Waits for typing to pause before searching, and drops the results of a search that was typed over.
        .task(id: query) {
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            do {
                let loaded = try await actions.loadCandidates(query)
                guard !Task.isCancelled else { return }
                candidates = loaded
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            message(error)
        } else if let candidates {
            if candidates.isEmpty {
                message("Nobody matches \"\(query)\".")
            }
            let suggested = candidates.filter(\.isSuggested)
            if !suggested.isEmpty {
                sectionTitle("Suggestions")
                ForEach(suggested) { row($0) }
                sectionTitle("Everyone else")
            }
            ForEach(candidates.filter { !$0.isSuggested }) { row($0) }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
    }

    private func row(_ candidate: ReviewerCandidate) -> some View {
        ReviewerPickerRow(candidate: candidate,
                          isRequested: reviewers.isRequested(candidate.id),
                          isWorking: actions.inFlight.contains(candidate.id)) {
            actions.setRequested(candidate.name, candidate.kind, !reviewers.isRequested(candidate.id))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

private struct ReviewerPickerRow: View {
    let candidate: ReviewerCandidate
    let isRequested: Bool
    let isWorking: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Group {
                    if isWorking {
                        ProgressView().controlSize(.mini)
                    } else if isRequested {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .frame(width: 14)

                switch candidate.kind {
                case .user:
                    AvatarView(login: candidate.name, size: 20)
                case .team:
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.secondary.opacity(0.14)))
                }

                Text(candidate.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let detail = candidate.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovering ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .onHover { isHovering = $0 }
        .help(isRequested ? "Remove the review request" : "Request a review")
    }
}
