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
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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

        }
        .modifier(PullRequestRowSurface(isSelected: isSelected, isHovering: isHovering))
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var outcomeIcon: some View {
        Image(systemName: pr.outcome.iconName)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(outcomeColor)
            .frame(width: 22, height: 22)
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
            return Color.green
        case .closed:
            return Color.red
        }
    }


}
