import SwiftUI

struct PRHistoryRow: View {
    let pr: PullRequestHistoryRow
    let isSelected: Bool
    let relativeFormatter: RelativeDateTimeFormatter
    let now: Date

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            outcomeIcon

            VStack(alignment: .leading, spacing: 6) {
                Text(pr.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .help(pr.title)

                Text("\(pr.repoFullName)#\(String(pr.number))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    outcomeBadge

                    Text(outcomeDateText)
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

    private var outcomeIcon: some View {
        Image(systemName: pr.outcome.iconName)
            .font(.title)
            .foregroundStyle(outcomeColor)
            .frame(width: 30)
    }

    private var outcomeBadge: some View {
        Text(pr.outcome.title.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(outcomeColor.opacity(0.16))
            )
            .foregroundStyle(outcomeColor)
    }

    private var outcomeDateText: String {
        let date = pr.mergedAt ?? pr.closedAt ?? pr.updatedAt
        return "\(pr.outcome.title) \(relativeFormatter.localizedString(for: date, relativeTo: now))"
    }

    private var outcomeColor: Color {
        switch pr.outcome {
        case .merged:
            return Color(red: 0.10, green: 0.43, blue: 0.24)
        case .closed:
            return Color(red: 0.72, green: 0.16, blue: 0.16)
        }
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
