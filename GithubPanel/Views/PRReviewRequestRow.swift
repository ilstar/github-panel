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

                    RowSubtitle(text: "\(pr.repoFullName)#\(String(pr.number))", detail: detailText) {
                        if pr.isDraft {
                            TagView(text: "DRAFT")
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

    private var detailText: String {
        let updated = "updated \(relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: now))"
        guard let author = pr.authorLogin else { return updated.capitalizedFirstLetter }
        return "by \(author) · \(updated)"
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}
