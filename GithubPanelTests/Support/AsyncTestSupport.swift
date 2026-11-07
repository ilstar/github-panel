import Foundation
import XCTest

func XCTAssertThrowsAsync(_ expression: @autoclosure () async throws -> Void,
                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 0)
}

/// Holds fake GitHub calls until the test opens it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
