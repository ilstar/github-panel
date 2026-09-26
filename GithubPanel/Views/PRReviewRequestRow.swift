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
                RowIcon(systemName: "eye.circle.fill", color: Theme.amber)

                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                        .help(pr.title)

                    HStack(spacing: 6) {
                        if pr.isDraft {
                            TagView(text: "DRAFT")
                        }

                        Text("\(pr.repoFullName)#\(String(pr.number))")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(detailText)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                    .font(.caption)
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
