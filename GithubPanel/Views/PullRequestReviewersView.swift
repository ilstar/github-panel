import SwiftUI

/// GitHub's Reviewers list: the overall verdict, then each requested or reviewing user and team with their status.
struct PullRequestReviewersView: View {
    let reviewers: PullRequestReviewers

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if reviewers.reviewers.isEmpty {
                Text("No reviewers requested.")
                    .prFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(reviewers.reviewers) { reviewer in
                        PullRequestReviewerRow(reviewer: reviewer)
                    }
                }
            }
        }
    }

    private var header: some View {
        let summary = reviewers.summary
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Reviewers")
                .prFont(.callout, weight: .semibold)
            if let tone = summary.tone {
                TagView(text: summary.title.uppercased(), color: tone.color)
            }
            if let detail = summary.detail {
                Text(detail)
                    .prFont(.caption1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct PullRequestReviewerRow: View {
    let reviewer: PullRequestReviewer

    var body: some View {
        HStack(spacing: 8) {
            avatar
            Text(reviewer.name)
                .prFont(.callout, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if reviewer.isCodeOwner {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Requested as a code owner")
            }
            if !reviewer.onBehalfOf.isEmpty {
                Text("for \(reviewer.onBehalfOf.joined(separator: ", "))")
                    .prFont(.caption1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            statusIcon
                .help(reviewer.helpText)
                .accessibilityLabel(reviewer.helpText)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        switch reviewer.kind {
        case .user:
            AvatarView(login: reviewer.name, size: 20)
        case .team:
            Image(systemName: "person.2.fill")
                .font(.system(size: 10, weight: .semibold))
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
