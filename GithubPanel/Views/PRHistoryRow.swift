import SwiftUI

struct PRHistoryRow: View {
    let pr: PullRequestHistoryRow
    let isSelected: Bool
    let relativeFormatter: RelativeDateTimeFormatter
    let now: Date

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RowIcon(systemName: pr.outcome.iconName, color: outcomeColor, inCircle: true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                        .help(pr.title)

                    RowSubtitle(text: "\(pr.repoFullName)#\(String(pr.number))", detail: outcomeDateText) {
                        TagView(text: pr.outcome.title.uppercased(), color: outcomeColor)
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

    private var outcomeDateText: String {
        let date = pr.mergedAt ?? pr.closedAt ?? pr.updatedAt
        return "\(pr.outcome.title) \(relativeFormatter.localizedString(for: date, relativeTo: now))"
    }

    private var outcomeColor: Color {
        switch pr.outcome {
        case .merged:
            return Theme.purple
        case .closed:
            return Theme.red
        }
    }
}
