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
                .font(.title)
                .foregroundStyle(accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 6) {
                Text(pr.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
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
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.95 : 0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.04), radius: 8, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        Color(red: 0.55, green: 0.38, blue: 0.10)
    }

    private var cardFill: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(
                LinearGradient(colors: [
                    Color(red: 0.93, green: 0.96, blue: 1.0),
                    Color(red: 0.98, green: 0.99, blue: 1.0)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        return AnyShapeStyle(Color.white.opacity(isHovering ? 0.95 : 0.9))
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}
