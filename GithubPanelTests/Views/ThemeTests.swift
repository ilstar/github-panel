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

    @MainActor
    func testWindowBackdropLetsTheDesktopShowThrough() {
        // The window and sidebar materials wash the desktop out to near white behind the glass sidebar.
        let view = WindowBackdrop.makeView()
        XCTAssertEqual(view.material, .fullScreenUI)
        XCTAssertEqual(view.blendingMode, .behindWindow)
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
