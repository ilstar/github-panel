import SwiftUI

/// Shared surfaces keep the list quiet and follow the user's macOS appearance.
enum PanelStyle {
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)

    static func rowFill(isSelected: Bool, isHovering: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        return Color.primary.opacity(isHovering ? 0.045 : 0.02)
    }
}

struct PullRequestRowSurface: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PanelStyle.rowFill(isSelected: isSelected, isHovering: isHovering))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 24)
                        .padding(.leading, 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
