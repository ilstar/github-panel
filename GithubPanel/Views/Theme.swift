import SwiftUI
import AppKit

/// Shared colors and small building blocks for a quiet, Things-like look:
/// flat rows on a soft background, one accent for selection, and color only where it carries meaning.
enum Theme {
    /// The list pane on the left, a shade off the white detail pane.
    static let listBackground = Color(light: NSColor(red: 0.965, green: 0.965, blue: 0.972, alpha: 1),
                                      dark: NSColor(red: 0.135, green: 0.135, blue: 0.145, alpha: 1))
    static let rowHover = Color.primary.opacity(0.045)
    static let rowSelection = Color.accentColor.opacity(0.14)
    /// A soft fill for cards such as comments and the token form.
    static let cardFill = Color.primary.opacity(0.035)
    static let hairline = Color.primary.opacity(0.08)

    static let green = Color(light: NSColor(red: 0.13, green: 0.55, blue: 0.29, alpha: 1),
                             dark: NSColor(red: 0.30, green: 0.78, blue: 0.45, alpha: 1))
    static let red = Color(light: NSColor(red: 0.80, green: 0.18, blue: 0.20, alpha: 1),
                           dark: NSColor(red: 1.00, green: 0.42, blue: 0.40, alpha: 1))
    static let purple = Color(light: NSColor(red: 0.51, green: 0.31, blue: 0.85, alpha: 1),
                              dark: NSColor(red: 0.70, green: 0.55, blue: 1.00, alpha: 1))
    static let amber = Color(light: NSColor(red: 0.80, green: 0.50, blue: 0.05, alpha: 1),
                             dark: NSColor(red: 1.00, green: 0.72, blue: 0.30, alpha: 1))

    static let rowCornerRadius: CGFloat = 8
}

extension Color {
    /// A color that follows the window's light or dark appearance.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// A small rounded label such as DRAFT or MERGED, like a tag in Things.
struct TagView: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.3)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.13)))
            .foregroundStyle(color)
    }
}

/// The flat, rounded background behind a list row: a faint fill on hover, the accent when selected.
struct ListRowBackground: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                    .fill(isSelected ? Theme.rowSelection : isHovering ? Theme.rowHover : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    func listRowBackground(isSelected: Bool, isHovering: Bool) -> some View {
        modifier(ListRowBackground(isSelected: isSelected, isHovering: isHovering))
    }
}

/// A borderless toolbar button that shows a soft rounded fill on hover and press.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .foregroundStyle(isHovering && isEnabled ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : isHovering && isEnabled ? 0.06 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovering = $0 }
        }
    }
}

/// The small colored disc at the leading edge of a row. Takes a `.circle.fill` symbol, or with
/// `inCircle` a bare glyph that is drawn white on the colored disc.
struct RowIcon: View {
    let systemName: String
    let color: Color
    var inCircle = false

    var body: some View {
        Group {
            if inCircle {
                Image(systemName: systemName)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(color))
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, color)
            }
        }
        .frame(width: 20)
    }
}
