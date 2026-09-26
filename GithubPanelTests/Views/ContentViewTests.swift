import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

@MainActor
final class ContentViewTests: XCTestCase {
    func testEmptyPullRequestsBackgroundAssetIsAvailable() {
        XCTAssertNotNil(NSImage(named: EmptyPullRequestsBackground.imageName))
    }

    func testTabPickerStartsAtTheLeadingEdgeOfItsRow() throws {
        let row = HStack {
            PullRequestTabPicker(selection: .constant(.open))
            Spacer()
        }
        .frame(width: 600, height: 40)
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        host.layoutSubtreeIfNeeded()

        let control = try XCTUnwrap(segmentedControl(in: host))
        let frame = control.convert(control.bounds, to: host)
        XCTAssertEqual(frame.minX, 0, accuracy: 1)
    }

    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for subview in view.subviews {
            if let control = segmentedControl(in: subview) { return control }
        }
        return nil
    }
}
