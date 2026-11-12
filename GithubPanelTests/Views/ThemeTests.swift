import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

final class ThemeTests: XCTestCase {
    @MainActor
    func testSelectedCardIsDistinctFromNormalAndHoveredCards() throws {
        for scheme in [ColorScheme.light, .dark] {
            func pixel(selected: Bool, hovered: Bool) throws -> NSColor {
                let view = Color.clear.frame(width: 180, height: 32)
                    .listRowBackground(isSelected: selected, isHovering: hovered, isCard: true)
                    .background(Theme.windowBackground)
                    .accentColor(.blue)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                                                    y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            }

            let selected = try pixel(selected: true, hovered: false)
            for hovered in [false, true] {
                let unselected = try pixel(selected: false, hovered: hovered)
                let difference = max(abs(selected.redComponent - unselected.redComponent),
                                     abs(selected.greenComponent - unselected.greenComponent),
                                     abs(selected.blueComponent - unselected.blueComponent))
                XCTAssertGreaterThan(difference, 0.08, "\(scheme), hovered: \(hovered)")
            }
        }
    }

    @MainActor
    func testCardHighlightMovesToTheNewSelection() throws {
        var selection: Binding<Int>?
        let host = NSHostingView(rootView: SelectionRows { selection = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        func rowColors() throws -> [CGFloat] {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try [0.25, 0.75].flatMap { fraction -> [CGFloat] in
                let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                                                         y: Int(CGFloat(bitmap.pixelsHigh) * fraction)))
                let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
                return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            }
        }

        let first = try rowColors()
        XCTAssertGreaterThan((0..<3).map { abs(first[$0] - first[$0 + 3]) }.max() ?? 0, 0.08)
        try XCTUnwrap(selection).wrappedValue = 1
        let second = try rowColors()
        for channel in 0..<3 {
            XCTAssertEqual(first[channel], second[channel + 3], accuracy: 0.02)
            XCTAssertEqual(first[channel + 3], second[channel], accuracy: 0.02)
        }
        try XCTUnwrap(selection).wrappedValue = 0
        let third = try rowColors()
        for channel in first.indices {
            XCTAssertEqual(first[channel], third[channel], accuracy: 0.02)
        }
    }

    func testAdaptiveColorFollowsTheAppearance() throws {
        let color = NSColor(Color(light: .white, dark: .black))

        XCTAssertEqual(try resolvedWhite(color, in: .aqua), 1, accuracy: 0.01)
        XCTAssertEqual(try resolvedWhite(color, in: .darkAqua), 0, accuracy: 0.01)
    }

    func testHistoryIconsAreBareGlyphsForTheRowDisc() {
        // History rows draw the outcome glyph white on a colored disc, so it must not bring its own circle.
        for outcome in [PullRequestHistoryOutcome.merged, .closed] {
            XCTAssertFalse(outcome.iconName.contains("circle"), outcome.iconName)
        }
    }

    func testPullRequestStateIconsAreBareGlyphsForTheRowDisc() {
        for state in [PullRequestState.conflict, .draft, .queued, .autoMerge, .open] {
            XCTAssertFalse(state.symbolName.contains("circle"), state.symbolName)
        }
    }

    func testPullRequestGlyphCanLeaveOutItsArrowhead() {
        // The arrowhead is one move and two lines; the row icon drops it.
        func elementCount(_ glyph: PullRequestGlyph) -> Int {
            var count = 0
            glyph.path(in: CGRect(x: 0, y: 0, width: 24, height: 24)).forEach { _ in count += 1 }
            return count
        }

        XCTAssertEqual(elementCount(PullRequestGlyph()) - elementCount(PullRequestGlyph(showsArrow: false)), 3)
    }

    func testAvatarColorStaysTheSameForALogin() {
        XCTAssertEqual(AvatarView.paletteIndex(for: "octocat"), AvatarView.paletteIndex(for: "octocat"))
        XCTAssertEqual(AvatarView.paletteIndex(for: "Octocat"), AvatarView.paletteIndex(for: "octocat"))
        // "octocat" sums to 749, and 749 % 6 is 5.
        XCTAssertEqual(AvatarView.paletteIndex(for: "octocat"), 5)
        XCTAssertEqual(AvatarView.paletteIndex(for: ""), 0)
    }

    func testAvatarColorIsAlwaysInThePalette() {
        for login in ["a", "hubot", "monalisa", "mock-user", "dependabot[bot]", "名前"] {
            XCTAssertTrue(AvatarView.palette.indices.contains(AvatarView.paletteIndex(for: login)), login)
        }
    }

    func testSelectedRowIsARaisedChipInBothAppearances() throws {
        // The chip is near-white in light mode and a faint white in dark mode, never the accent tint.
        let color = NSColor(Theme.rowSelection)
        XCTAssertGreaterThan(try resolvedWhite(color, in: .aqua), 0.95)
        XCTAssertGreaterThan(try resolvedWhite(color, in: .darkAqua), 0.95)
    }

    func testWindowAndSidebarAreOpaqueSoTheDesktopNeverShowsThrough() throws {
        let colors = [Theme.windowBackground, Theme.contentBackground, SidebarGradient.startColor, SidebarGradient.endColor]
        for color in colors {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                XCTAssertEqual(try resolvedAlpha(NSColor(color), in: name), 1, accuracy: 0.001, "\(color) in \(name.rawValue)")
            }
        }
    }

    func testSidebarGradientRunsFromLighterToDarkerInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let start = try resolvedWhite(NSColor(SidebarGradient.startColor), in: name)
            let end = try resolvedWhite(NSColor(SidebarGradient.endColor), in: name)
            XCTAssertGreaterThan(start, end, name.rawValue)
        }
    }

    func testSidebarWashIsMoreOpaqueForAWeakerGradient() {
        // Graphite at 10% strength, as chosen on the design canvas.
        XCTAssertEqual(SidebarGradient.strength, 10)
        XCTAssertEqual(SidebarGradient.washOpacity(strength: 10, isDark: false), 0.72, accuracy: 0.001)
        XCTAssertEqual(SidebarGradient.washOpacity(strength: 10, isDark: true), 0.695, accuracy: 0.001)
        XCTAssertEqual(SidebarGradient.washOpacity(strength: 100, isDark: false), 0.18, accuracy: 0.001)
        XCTAssertEqual(SidebarGradient.washOpacity(strength: 0, isDark: false), 0.78, accuracy: 0.001)
        // Out-of-range strengths are clamped.
        XCTAssertEqual(SidebarGradient.washOpacity(strength: 150, isDark: true), 0.20, accuracy: 0.001)
    }

    func testActivityCardsHaveOpaqueSurfacesAndVisibleBordersInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let fill = NSColor(Theme.conversationCardFill)
            let border = NSColor(Theme.activityCardBorder)
            XCTAssertEqual(try resolvedAlpha(fill, in: name), 1, accuracy: 0.001)
            XCTAssertEqual(try resolvedAlpha(border, in: name), 1, accuracy: 0.001)
            let difference = abs(try resolvedWhite(fill, in: name) - resolvedWhite(border, in: name))
            XCTAssertGreaterThan(difference, 0.08)
        }
    }

    private func resolvedAlpha(_ color: NSColor, in name: NSAppearance.Name) throws -> CGFloat {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var alpha: CGFloat = -1
        appearance.performAsCurrentDrawingAppearance {
            alpha = color.usingColorSpace(.sRGB)?.alphaComponent ?? -1
        }
        return alpha
    }

    private func resolvedWhite(_ color: NSColor, in name: NSAppearance.Name) throws -> CGFloat {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var white: CGFloat = -1
        appearance.performAsCurrentDrawingAppearance {
            white = color.usingColorSpace(.genericGray)?.whiteComponent ?? -1
        }
        return white
    }
}

private struct SelectionRows: View {
    @State private var selectedID = 0
    let exposeSelection: (Binding<Int>) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<2) { id in
                    Color.clear.frame(height: 32)
                        .listRowBackground(isSelected: selectedID == id, isHovering: false, isCard: true)
                }
            }
        }
        .padding(10)
        .background(Color.gray)
        .accentColor(.blue)
        .environment(\.colorScheme, .light)
        .onAppear { exposeSelection($selectedID) }
    }
}
