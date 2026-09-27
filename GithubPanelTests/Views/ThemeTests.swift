import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

final class ThemeTests: XCTestCase {
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
