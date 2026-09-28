import SwiftUI

struct PRReviewRequestRow: View {
    let pr: ReviewRequestRow
    let isSelected: Bool
    let relativeFormatter: RelativeDateTimeFormatter
    let now: Date

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                reviewerIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .help(pr.title)

                    RowSubtitle(text: Self.subtitleText(for: pr), detail: detailText, compactDetail: whenText) {
                        if pr.isDraft {
                            TagView(text: "DRAFT")
                        }
                        if let checkState = pr.checkState {
                            Image(systemName: checkState.symbolName)
                                .foregroundStyle(checkState.tint)
                                .help(checkState.descriptionText)
                                .accessibilityLabel(checkState.descriptionText)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovering || isSelected ? 1 : 0)
        }
        .listRowBackground(isSelected: isSelected, isHovering: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    /// The author's avatar, like the design's review rows. The eye stands in when GitHub gives no author.
    @ViewBuilder
    private var reviewerIcon: some View {
        if let author = pr.authorLogin {
            AvatarView(login: author, size: 21)
                .frame(width: 22)
        } else {
            RowIcon(systemName: "eye.circle.fill", color: Theme.amber)
        }
    }

    /// "owner/repo#12 · +120 −30": where the pull request lives and how big it is.
    static func subtitleText(for pr: ReviewRequestRow) -> String {
        let place = "\(pr.repoFullName)#\(String(pr.number))"
        guard let additions = pr.additions, let deletions = pr.deletions else { return place }
        return "\(place) · +\(additions) −\(deletions)"
    }

    private var detailText: String {
        guard let author = pr.authorLogin else { return whenText }
        return "by \(author) · \(whenText.lowercasedFirstLetter)"
    }

    /// How long the author has waited on me, or when the pull request last changed when GitHub does not say.
    /// Kept when the row is too narrow for the author, who is on the avatar anyway.
    private var whenText: String {
        pr.requestedAt.map { "Requested \(relativeFormatter.localizedString(for: $0, relativeTo: now))" }
            ?? "Updated \(relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: now))"
    }
}

private extension String {
    var lowercasedFirstLetter: String {
        prefix(1).lowercased() + dropFirst()
    }
}
