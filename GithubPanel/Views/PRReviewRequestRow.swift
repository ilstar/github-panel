import SwiftUI

struct PRReviewRequestRow: View {
    let pr: ReviewRequestRow
    let isSelected: Bool
    let relativeFormatter: RelativeDateTimeFormatter
    let now: Date

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(pr.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(pr.title)

                Text("\(pr.repoFullName)#\(String(pr.number))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if pr.isDraft {
                        draftBadge
                    }

                    Text(detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)

        }
        .modifier(PullRequestRowSurface(isSelected: isSelected, isHovering: isHovering))
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var draftBadge: some View {
        Text("DRAFT")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
            )
            .foregroundStyle(.secondary)
    }

    private var detailText: String {
        let updated = "updated \(relativeFormatter.localizedString(for: pr.updatedAt, relativeTo: now))"
        guard let author = pr.authorLogin else { return updated.capitalizedFirstLetter }
        return "by \(author) · \(updated)"
    }

    private var accentColor: Color {
        Color.orange
    }


}

private extension String {
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}
