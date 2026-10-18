import XCTest
import WebKit
@testable import GithubPanel

@MainActor
final class WebExtensionsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try WebExtensionFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testInstallingLoadsTheExtensionInWebKit() async throws {
        try XCTSkipUnless(WebExtensions.isSupported, "WebKit runs extensions from macOS 15.4")
        let extensions = WebExtensions(library: WebExtensionLibrary(root: directory.appendingPathComponent("Library")))
        let source = try WebExtensionFixtures.writeExtension(in: directory.appendingPathComponent("source"))

        try await extensions.install(from: source)

        let installed = try XCTUnwrap(extensions.installed.first)
        let status = try XCTUnwrap(extensions.statuses[installed.id])
        XCTAssertNil(status.error)
        XCTAssertTrue(status.hasAction)
        XCTAssertFalse(status.hasOptionsPage)
        XCTAssertEqual(extensions.actionExtensions.map(\.id), [installed.id])
    }

    func testTurningOffUnloadsAndTurningOnLoadsAgain() async throws {
        try XCTSkipUnless(WebExtensions.isSupported, "WebKit runs extensions from macOS 15.4")
        let extensions = WebExtensions(library: WebExtensionLibrary(root: directory.appendingPathComponent("Library")))
        try await extensions.install(from: WebExtensionFixtures.writeExtension(in: directory.appendingPathComponent("s")))
        let id = try XCTUnwrap(extensions.installed.first?.id)

        await extensions.setEnabled(false, for: id)
        XCTAssertEqual(extensions.installed.first?.isEnabled, false)
        XCTAssertNil(extensions.statuses[id])
        XCTAssertTrue(extensions.actionExtensions.isEmpty)

        await extensions.setEnabled(true, for: id)
        XCTAssertNotNil(extensions.statuses[id])
        XCTAssertNil(extensions.statuses[id]?.error)
    }

    func testRemovingForgetsTheExtension() async throws {
        try XCTSkipUnless(WebExtensions.isSupported, "WebKit runs extensions from macOS 15.4")
        let library = WebExtensionLibrary(root: directory.appendingPathComponent("Library"))
        let extensions = WebExtensions(library: library)
        try await extensions.install(from: WebExtensionFixtures.writeExtension(in: directory.appendingPathComponent("s")))
        let id = try XCTUnwrap(extensions.installed.first?.id)

        extensions.remove(id: id)

        XCTAssertTrue(extensions.installed.isEmpty)
        XCTAssertNil(extensions.statuses[id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.directory(for: id).path))
    }

    func testPaneWebViewsAreGivenTheExtensionController() throws {
        try XCTSkipUnless(WebExtensions.isSupported, "WebKit runs extensions from macOS 15.4")
        guard #available(macOS 15.4, *) else { return }
        let session = PullRequestWebSession()
        defer { session.close() }
        XCTAssertNotNil(session.webView.configuration.webExtensionController)
    }
}
