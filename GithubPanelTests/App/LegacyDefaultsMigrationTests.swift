import Foundation
import XCTest
@testable import GithubPanel

final class LegacyDefaultsMigrationTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyDefaultsMigrationTests-\(UUID().uuidString)").path
        defaults = UserDefaults(suiteName: path)
    }

    func testCopiesLegacySettingsAndMarksMigrationDone() {
        LegacyDefaultsMigration.migrate(from: ["GithubPanel.appearance": "dark",
                                               "diffHideWhitespace": true],
                                        into: defaults)

        XCTAssertEqual(defaults.string(forKey: "GithubPanel.appearance"), "dark")
        XCTAssertTrue(defaults.bool(forKey: "diffHideWhitespace"))
        XCTAssertTrue(defaults.bool(forKey: LegacyDefaultsMigration.migratedKey))
    }

    func testKeepsValuesAlreadySetUnderTheNewIdentifier() {
        defaults.set("light", forKey: "GithubPanel.appearance")

        LegacyDefaultsMigration.migrate(from: ["GithubPanel.appearance": "dark"], into: defaults)

        XCTAssertEqual(defaults.string(forKey: "GithubPanel.appearance"), "light")
    }

    func testRunsOnlyOnce() {
        LegacyDefaultsMigration.migrate(from: nil, into: defaults)
        LegacyDefaultsMigration.migrate(from: ["GithubPanel.appearance": "dark"], into: defaults)

        XCTAssertTrue(defaults.bool(forKey: LegacyDefaultsMigration.migratedKey))
        XCTAssertNil(defaults.string(forKey: "GithubPanel.appearance"))
    }

    func testAppUsesTheNewBundleIdentifierAndMigratesFromTheOldOne() throws {
        let project = try String(contentsOf: TestPaths.url("GithubPanel.xcodeproj/project.pbxproj"), encoding: .utf8)

        XCTAssertEqual(project.components(separatedBy: "PRODUCT_BUNDLE_IDENTIFIER = io.github.ilstar.github-panel;").count - 1, 2)
        XCTAssertFalse(project.contains(LegacyDefaultsMigration.legacyDomain))
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, LegacyDefaultsMigration.legacyDomain)
    }

    func testAppMigratesBeforeReadingAnySettings() throws {
        let source = try String(contentsOf: TestPaths.url("GithubPanel/App/GithubPanelApp.swift"), encoding: .utf8)

        let migration = try XCTUnwrap(source.range(of: "LegacyDefaultsMigration.runIfNeeded()")?.lowerBound)
        let monitor = try XCTUnwrap(source.range(of: "let monitor = Self.makeMonitor()")?.lowerBound)
        XCTAssertLessThan(migration, monitor)
    }
}
