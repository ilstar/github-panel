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

    private func resolvedWhite(_ color: NSColor, in name: NSAppearance.Name) throws -> CGFloat {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var white: CGFloat = -1
        appearance.performAsCurrentDrawingAppearance {
            white = color.usingColorSpace(.genericGray)?.whiteComponent ?? -1
        }
        return white
    }
}
