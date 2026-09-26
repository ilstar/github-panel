import Foundation
import XCTest

final class TestHostTokenStoreTests: XCTestCase {
    func testTestHostUsesInMemoryTokenStoreBeforeKeychain() throws {
        let source = try String(contentsOf: TestPaths.url("GithubPanel/App/GithubPanelApp.swift"), encoding: .utf8)

        let testGuard = try XCTUnwrap(source.range(of: "if ProcessInfo.processInfo.isRunningTests {\n            return PRMonitor(tokenStore: InMemoryTokenStore())")?.lowerBound)
        let defaultMonitor = try XCTUnwrap(source.range(of: "return PRMonitor()")?.lowerBound)
        XCTAssertLessThan(testGuard, defaultMonitor)
    }
}
