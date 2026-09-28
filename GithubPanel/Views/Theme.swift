import SwiftUI
import AppKit

/// Shared colors and small building blocks for a glassy, current-macOS look: the list floats in a
/// sidebar with its own soft gradient, controls are capsules, the selected row is a raised chip,
/// and color appears only where it carries meaning. Nothing shows the desktop through, so the window
/// looks the same whatever is behind it.
enum Theme {
    /// The window behind the floating sidebar, around its edges.
    static let windowBackground = Color(light: NSColor(red: 0.925, green: 0.933, blue: 0.953, alpha: 1),
                                        dark: NSColor(red: 0.106, green: 0.106, blue: 0.125, alpha: 1))
    /// The pull request pane.
    static let contentBackground = Color(light: NSColor(red: 0.992, green: 0.992, blue: 0.996, alpha: 1),
                                         dark: NSColor(red: 0.118, green: 0.118, blue: 0.137, alpha: 1))
    static let rowHover = Color(light: NSColor(white: 1, alpha: 0.4),
                                dark: NSColor(white: 1, alpha: 0.06))
    /// The selected row: a raised white chip rather than an accent tint.
    static let rowSelection = Color(light: NSColor(white: 1, alpha: 0.84),
                                    dark: NSColor(white: 1, alpha: 0.13))
    /// Capsule controls that sit on the sidebar or a card, such as the tab switcher and refresh button.
    static let controlFill = Color(light: NSColor(white: 1, alpha: 0.58),
                                   dark: NSColor(white: 1, alpha: 0.08))
    /// The selected segment of a ``GlassSegmentedControl``.
    static let segmentSelection = Color(light: .white,
                                        dark: NSColor(white: 1, alpha: 0.2))
    /// The bright edge along the top of glass surfaces.
    static let glassHighlight = Color(light: NSColor(white: 1, alpha: 0.9),
                                      dark: NSColor(white: 1, alpha: 0.14))
    /// A soft fill for cards such as the description, comments and the token form.
    static let cardFill = Color(light: NSColor(white: 1, alpha: 0.72),
                                dark: NSColor(white: 1, alpha: 0.05))
    static let hairline = Color.primary.opacity(0.08)
    /// The Merge and Add to queue buttons: a flat green that keeps white text readable.
    static let mergeFill = Color(red: 0.122, green: 0.498, blue: 0.239)

    static let green = Color(light: NSColor(red: 0.13, green: 0.55, blue: 0.29, alpha: 1),
                             dark: NSColor(red: 0.30, green: 0.78, blue: 0.45, alpha: 1))
    static let red = Color(light: NSColor(red: 0.80, green: 0.18, blue: 0.20, alpha: 1),
                           dark: NSColor(red: 1.00, green: 0.42, blue: 0.40, alpha: 1))
    static let purple = Color(light: NSColor(red: 0.51, green: 0.31, blue: 0.85, alpha: 1),
                              dark: NSColor(red: 0.70, green: 0.55, blue: 1.00, alpha: 1))
    static let amber = Color(light: NSColor(red: 0.80, green: 0.50, blue: 0.05, alpha: 1),
                             dark: NSColor(red: 1.00, green: 0.72, blue: 0.30, alpha: 1))
    /// Branch name tags, in GitHub's blue on a pale blue fill.
    static let branch = Color(light: NSColor(red: 0.035, green: 0.412, blue: 0.855, alpha: 1),
                              dark: NSColor(red: 0.267, green: 0.576, blue: 0.973, alpha: 1))
    static let branchFill = Color(light: NSColor(red: 0.867, green: 0.957, blue: 1.0, alpha: 1),
                                  dark: NSColor(red: 0.220, green: 0.545, blue: 0.992, alpha: 0.15))
    static let branchFillHover = Color(light: NSColor(red: 0.776, green: 0.914, blue: 1.0, alpha: 1),
                                       dark: NSColor(red: 0.220, green: 0.545, blue: 0.992, alpha: 0.25))

    static let rowCornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 18
    static let sidebarCornerRadius: CGFloat = 20
    /// The gap between the floating sidebar and the window edges.
    static let sidebarInset: CGFloat = 8
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
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.4)
            // A tag stays on one line; the row's other text truncates to make room.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}

/// The rounded background behind a list row: a faint fill on hover, a raised chip when selected.
struct ListRowBackground: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                shape
                    .fill(isSelected ? Theme.rowSelection : isHovering ? Theme.rowHover : Color.clear)
                    .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5).opacity(isSelected ? 0.7 : 0))
                    .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 5, y: 2)
            )
            .contentShape(shape)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    func listRowBackground(isSelected: Bool, isHovering: Bool) -> some View {
        modifier(ListRowBackground(isSelected: isSelected, isHovering: isHovering))
    }
}

/// The small second line of a list row. The faint detail, such as "Updated 1 hr. ago", drops out
/// when the row is too narrow for it rather than trailing off as "Upda…".
struct RowSubtitle<Leading: View>: View {
    let text: String
    let detail: String
    /// A shorter detail for when the full one does not fit. Nil drops the detail instead.
    var compactDetail: String?
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(detail: detail)
            if let compactDetail {
                line(detail: compactDetail)
            }
            line(detail: nil)
        }
        .font(.caption)
    }

    private func line(detail: String?) -> some View {
        HStack(spacing: 6) {
            leading()
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

extension RowSubtitle where Leading == EmptyView {
    init(text: String, detail: String) {
        self.init(text: text, detail: detail) { EmptyView() }
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
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(color))
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, color)
            }
        }
        .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
        .frame(width: 22)
    }
}

// MARK: - Glass

/// The sidebar's own background: two colors blending from the top left to the bottom right, under a
/// wash and a soft sheen along the top. It is opaque, so it looks the same whatever is behind the window.
struct SidebarGradient: View {
    /// The Graphite palette: a light gray into a cooler, darker gray.
    static let startColor = Color(light: NSColor(red: 0.827, green: 0.843, blue: 0.875, alpha: 1),
                                  dark: NSColor(red: 0.200, green: 0.216, blue: 0.247, alpha: 1))
    static let endColor = Color(light: NSColor(red: 0.682, green: 0.714, blue: 0.769, alpha: 1),
                                dark: NSColor(red: 0.133, green: 0.145, blue: 0.169, alpha: 1))
    /// How much of the gradient's color comes through the wash, from 0 to 100.
    static let strength: Double = 10
    /// The wash that softens the gradient: white in light mode, a dark gray in dark mode.
    static let wash = Color(light: NSColor(white: 1, alpha: washOpacity(strength: strength, isDark: false)),
                            dark: NSColor(red: 0.149, green: 0.149, blue: 0.180,
                                          alpha: washOpacity(strength: strength, isDark: true)))
    static let sheen = Color(light: NSColor(white: 1, alpha: 0.45),
                             dark: NSColor(white: 1, alpha: 0.06))
    /// How far down the sheen fades out, as a fraction of the height.
    static let sheenDepth: CGFloat = 0.26

    /// A weaker gradient gets a more opaque wash.
    static func washOpacity(strength: Double, isDark: Bool) -> CGFloat {
        let weakness = (100 - min(max(strength, 0), 100)) / 100
        return isDark ? 0.20 + weakness * 0.55 : 0.18 + weakness * 0.6
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Self.startColor, Self.endColor], startPoint: .topLeading, endPoint: .bottomTrailing)
            Self.wash
            LinearGradient(stops: [.init(color: Self.sheen, location: 0),
                                   .init(color: Self.sheen.opacity(0), location: Self.sheenDepth)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Where a glass surface sits, which decides how it is drawn.
enum GlassRole {
    /// A large panel such as the sidebar.
    case panel
    /// A control on a pane, such as a toolbar button group or the comment box.
    case control
}

extension View {
    /// A panel is the sidebar's gradient with a bright top edge and a hairline. A control is Liquid Glass
    /// on macOS 26 and later, and before that a soft fill with the same edges.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(_ role: GlassRole, in shape: S) -> some View {
        switch role {
        case .panel:
            background(SidebarGradient().clipShape(shape))
                .glassEdges(in: shape, shadowRadius: 18)
        case .control:
            if #available(macOS 26.0, *) {
                glassEffect(.regular.interactive(), in: shape)
            } else {
                background(shape.fill(Theme.controlFill).background(.ultraThinMaterial, in: shape))
                    .glassEdges(in: shape, shadowRadius: 3)
            }
        }
    }

    /// A control drawn on a glass panel, where Liquid Glass would stack on glass: a soft white capsule
    /// with the same edges as glass.
    func controlChrome<S: InsettableShape>(in shape: S) -> some View {
        background(shape.fill(Theme.controlFill))
            .glassEdges(in: shape, shadowRadius: 1.5)
    }

    /// The bright top edge, hairline and soft shadow shared by glass surfaces.
    func glassEdges<S: InsettableShape>(in shape: S, shadowRadius: CGFloat) -> some View {
        overlay(
            shape.strokeBorder(
                LinearGradient(colors: [Theme.glassHighlight, Theme.glassHighlight.opacity(0.2)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        )
        .overlay(shape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: shadowRadius, y: shadowRadius / 3)
    }
}

private struct TitleBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The height of the window's title bar strip when a view runs up into it, as in the main window.
    var titleBarHeight: CGFloat? {
        get { self[TitleBarHeightKey.self] }
        set { self[TitleBarHeightKey.self] = newValue }
    }
}

extension View {
    /// Hides the focus ring on custom controls whose selection already shows focus. Needs macOS 14.
    @ViewBuilder
    func focusEffectDisabledIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

/// A segmented control drawn as a capsule with a raised white segment that slides to the selection.
struct GlassSegmentedControl<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    @Binding var selection: Value
    let segments: [Segment]
    /// Stretches the segments to share the full width, like the tab switcher over the list.
    var fillsWidth = false

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isSelected = segment.value == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selection = segment.value
                    }
                } label: {
                    Text(segment.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: fillsWidth ? .infinity : nil)
                        .frame(height: 28)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.segmentSelection)
                                    .shadow(color: .black.opacity(0.1), radius: 3, y: 1.5)
                                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabledIfAvailable()
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .controlChrome(in: Capsule())
    }
}

/// A round avatar with the login's first letter, in a color that stays the same for that login.
struct AvatarView: View {
    let login: String
    var size: CGFloat = 24

    var body: some View {
        Text(login.prefix(1).uppercased())
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.palette[Self.paletteIndex(for: login)]))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }

    static let palette: [Color] = [
        Color(red: 0.173, green: 0.624, blue: 0.455),
        Color(red: 0.184, green: 0.490, blue: 0.882),
        Color(red: 0.788, green: 0.282, blue: 0.431),
        Color(red: 0.431, green: 0.337, blue: 0.812),
        Color(red: 0.827, green: 0.447, blue: 0.118),
        Color(red: 0.059, green: 0.557, blue: 0.588)
    ]

    /// A stable index into ``palette``. `hashValue` changes between launches, so this sums the scalars.
    static func paletteIndex(for login: String) -> Int {
        let sum = login.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return sum % palette.count
    }
}

/// GitHub's pull request mark: two commits on a branch and an arrow into the base. Drawn on a 24-point grid
/// and scaled to fit, so stroke it with a width suited to its size.
struct PullRequestGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        let radius = 2.2 * scale
        for (x, y) in [(6.0, 6.2), (6.0, 18.0), (18.0, 18.0)] {
            path.addEllipse(in: CGRect(x: rect.minX + x * scale - radius, y: rect.minY + y * scale - radius,
                                       width: radius * 2, height: radius * 2))
        }
        // The branch's line between its two commits.
        path.move(to: point(6, 8.4))
        path.addLine(to: point(6, 15.8))
        // From the base commit up and over, ending in an arrow pointing left.
        path.move(to: point(18, 15.8))
        path.addLine(to: point(18, 10))
        path.addQuadCurve(to: point(15, 7), control: point(18, 7))
        path.addLine(to: point(10.5, 7))
        path.move(to: point(12.8, 4.6))
        path.addLine(to: point(10.4, 7))
        path.addLine(to: point(12.8, 9.4))
        return path
    }
}
