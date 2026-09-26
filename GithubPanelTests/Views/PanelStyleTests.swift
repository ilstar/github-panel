import AppKit
import SwiftUI
import XCTest
@testable import GithubPanel

@MainActor
final class PanelStyleTests: XCTestCase {
    func testSurfacesFollowLightAndDarkAppearance() throws {
        for color in [PanelStyle.sidebar, PanelStyle.surface] {
            let light = try brightness(color, appearance: .aqua)
            let dark = try brightness(color, appearance: .darkAqua)
            XCTAssertGreaterThan(light, 0.8)
            XCTAssertLessThan(dark, 0.3)
        }
    }

    func testListToolbarFitsAtMinimumPaneWidth() {
        let toolbar = HStack {
            Text("Pull Requests").font(.system(size: 24, weight: .bold))
            Spacer()
            RefreshPill(isLoading: false, isEnabled: true,
                        lastUpdatedView: Text("Updated 59 min. ago").font(.caption).frame(width: 110)) {}
        }
        let host = NSHostingView(rootView: toolbar)
        XCTAssertLessThanOrEqual(host.fittingSize.width, ListPaneLayout.minWidth - 48)
    }

    func testLongPullRequestTitleWrapsWithoutWideningTheList() {
        let width = ListPaneLayout.minWidth - 48
        let short = rowSize(title: "Fix refresh", width: width)
        let long = rowSize(title: "Improve pull request refresh coordination and preserve the selected review while background updates finish", width: width)
        XCTAssertEqual(short.width, width, accuracy: 1)
        XCTAssertEqual(long.width, width, accuracy: 1)
        XCTAssertGreaterThan(long.height, short.height)
    }

    private func rowSize(title: String, width: CGFloat) -> CGSize {
        let pr = PullRequestRow(id: "test", nodeID: "test", title: title, number: 42,
                                repoFullName: "example/project", htmlURL: URL(string: "https://github.com/example/project/pull/42")!,
                                headSHA: "abc", status: .success, isDraft: false, isAutoMergeEnabled: false,
                                canEnableAutoMerge: false, canDisableAutoMerge: false, isMergeQueueEnabled: false,
                                isInMergeQueue: false, mergeStateStatus: "CLEAN", updatedAt: Date())
        let row = PRRow(pr: pr, isSelected: true, relativeFormatter: RelativeDateTimeFormatter(),
                        now: Date(), isMerging: false, onAction: {})
            .frame(width: width)
        return NSHostingView(rootView: row).fittingSize
    }

    private func brightness(_ color: Color, appearance: NSAppearance.Name) throws -> CGFloat {
        var resolved: NSColor?
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.deviceRGB)
        }
        let rgb = try XCTUnwrap(resolved)
        return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
    }
}
