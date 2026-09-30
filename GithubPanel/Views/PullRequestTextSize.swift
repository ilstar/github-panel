import AppKit
import SwiftUI

enum PullRequestTextSize {
    static let defaultsKey = "GithubPanel.pullRequestTextSize"
    static let defaultSize = 13
    static let range = 11...20

    static func clamped(_ size: Int) -> Int {
        min(max(size, range.lowerBound), range.upperBound)
    }

    static func scaled(_ baseSize: CGFloat, setting: Int) -> CGFloat {
        baseSize + CGFloat(clamped(setting) - defaultSize)
    }

    // Cache the finite set of fonts and widths instead of measuring each visible diff row.
    private static let codeFonts = range.map {
        NSFont.monospacedSystemFont(ofSize: scaled(12, setting: $0), weight: .regular)
    }
    private static let codeWidths = codeFonts.map {
        ("0" as NSString).size(withAttributes: [.font: $0]).width
    }

    static func codeFont(setting: Int) -> NSFont {
        codeFonts[clamped(setting) - range.lowerBound]
    }

    static func codeCharacterWidth(setting: Int) -> CGFloat {
        codeWidths[clamped(setting) - range.lowerBound]
    }
}

private struct PullRequestTextSizeKey: EnvironmentKey {
    static let defaultValue = PullRequestTextSize.defaultSize
}

extension EnvironmentValues {
    var pullRequestTextSize: Int {
        get { self[PullRequestTextSizeKey.self] }
        set { self[PullRequestTextSizeKey.self] = PullRequestTextSize.clamped(newValue) }
    }
}

private struct PullRequestFont: ViewModifier {
    @Environment(\.pullRequestTextSize) private var textSize
    let baseSize: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: PullRequestTextSize.scaled(baseSize, setting: textSize),
                             weight: weight, design: design))
    }
}

extension View {
    func prFont(_ style: NSFont.TextStyle, weight: Font.Weight = .regular,
                design: Font.Design = .default) -> some View {
        prFont(size: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight, design: design)
    }

    func prFont(size: CGFloat, weight: Font.Weight = .regular,
                design: Font.Design = .default) -> some View {
        modifier(PullRequestFont(baseSize: size, weight: weight, design: design))
    }
}
