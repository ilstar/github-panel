import AppKit
import SwiftUI
import XCTest
@testable import GithubPanel

@MainActor
final class MyPRSelectionTests: XCTestCase {
    func testGroupedSelectionMovesBetweenSingleRowsAndStackMembers() async throws {
        try await checkSelection(grouped: true)
    }

    func testUngroupedSelectionMovesBetweenSingleRowsAndStackMembers() async throws {
        try await checkSelection(grouped: false)
    }

    func testSelectionMovesIntoAndOutOfForLater() async throws {
        try await checkSelection(grouped: true, forLater: true)
    }

    private func checkSelection(grouped: Bool, forLater: Bool = false) async throws {
        let settings: [String: Any] = [MyPullRequestSections.groupsByStatusDefaultsKey: grouped,
                                      CollapsedGroupsStorage.defaultsKey: "",
                                      ContentView.forLaterExpandedDefaultsKey: true,
                                      ListPaneLayout.widthDefaultsKey: 400,
                                      DetailPaneMode.defaultsKey: DetailPaneMode.native.rawValue]
        let saved = settings.keys.map { ($0, AppDefaults.store.object(forKey: $0)) }
        for (key, value) in settings { AppDefaults.store.set(value, forKey: key) }
        defer { for (key, value) in saved { AppDefaults.store.set(value, forKey: key) } }

        let api = FakeGitHubAPI()
        api.rows = [row(number: 1, status: .failure), row(number: 2, status: .failure),
                    row(number: 3, status: .success, baseRefName: "main", headRefName: "base"),
                    row(number: 4, status: .success, baseRefName: "base", headRefName: "top")]
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "test"))
        if forLater { monitor.moveToForLater(api.rows[3]) }
        let host = NSHostingView(rootView: ContentView().environmentObject(monitor)
            .accentColor(.blue).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await monitor.refreshNow()

        // Scan a blank strip at the right edge of the cards. Exactly one blue band should be present;
        // sampling the rendered view catches stale backgrounds even when the detail selection is correct.
        func selectedRowCenter(expectedNumber: Int) async throws -> CGFloat {
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let x = Int(384 * scale)
            var bands: [Range<Int>] = []
            var start: Int?
            for y in 0..<bitmap.pixelsHigh {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let selected = color.blueComponent - color.redComponent > 0.08
                    && color.blueComponent - color.greenComponent > 0.03
                if selected, start == nil { start = y }
                if !selected, let first = start {
                    if y - first > 6 { bands.append(first..<y) }
                    start = nil
                }
            }
            XCTAssertEqual(bands.count, 1, "Exactly one card must look selected, PR \(expectedNumber), grouped: \(grouped), For Later: \(forLater)")
            XCTAssertTrue(window.title.contains("#\(expectedNumber)"), window.title)
            let band = try XCTUnwrap(bands.first)
            return CGFloat(band.lowerBound + band.upperBound) / 2 / scale
        }

        func key(_ character: String) throws {
            window.makeFirstResponder(host)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: character, charactersIgnoringModifiers: character,
                                                      isARepeat: false, keyCode: character == "j" ? 38 : 40))
            NSApp.sendEvent(event)
        }

        let first = try await selectedRowCenter(expectedNumber: 1)
        var previous = first
        for number in 2...4 {
            try key("j")
            let center = try await selectedRowCenter(expectedNumber: number)
            XCTAssertGreaterThan(center, previous + 20)
            previous = center
        }
        try key("k")
        _ = try await selectedRowCenter(expectedNumber: 3)
        for number in [2, 1] {
            try key("k")
            _ = try await selectedRowCenter(expectedNumber: number)
        }
        for number in 2...4 {
            try key("j")
            _ = try await selectedRowCenter(expectedNumber: number)
        }

        // Refresh can reorder rows, move the selected PR between groups and dissolve its stack.
        // Keep selection on the same ID and verify that no old card keeps its highlight.
        api.rows = [row(number: 4, status: .failure), row(number: 2, status: .success),
                    row(number: 1, status: .success), row(number: 3, status: .success)]
        await monitor.refreshNow()
        _ = try await selectedRowCenter(expectedNumber: 4)
        try key("j")
        let next = forLater ? 4 : 2
        _ = try await selectedRowCenter(expectedNumber: next)

        // When refresh removes the selection, choose one surviving neighbor, with one highlight.
        api.rows.removeAll { $0.number == next }
        await monitor.refreshNow()
        _ = try await selectedRowCenter(expectedNumber: forLater ? 3 : 1)
    }
}
