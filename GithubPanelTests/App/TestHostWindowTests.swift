import AppKit
import XCTest
@testable import GithubPanel

@MainActor
final class TestHostWindowTests: XCTestCase {
    func testTestHostHasNoVisibleMainWindow() async throws {
        // Allow the initial SwiftUI scene and its window-hiding pass to finish.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && $0.canBecomeMain },
                       "The test host must keep its main window hidden")
    }
}
