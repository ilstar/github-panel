import SwiftUI

/// The Reviewers section of GitHub's pull request sidebar: each requested or reviewing user and team with
/// their status on the right, then the overall verdict.
struct PullRequestReviewersView: View {
    let reviewers: PullRequestReviewers

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reviewers")
                .prFont(.callout, weight: .semibold)
                .foregroundStyle(.secondary)

            if reviewers.reviewers.isEmpty {
                Text("No reviews")
                    .prFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(reviewers.reviewers) { reviewer in
                        PullRequestReviewerRow(reviewer: reviewer)
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
