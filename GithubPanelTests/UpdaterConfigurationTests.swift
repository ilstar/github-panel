import Foundation
import XCTest

final class UpdaterConfigurationTests: XCTestCase {
    func testInfoPlistConfiguresSecureAutomaticUpdates() throws {
        let plist = try loadInfoPlist()

        XCTAssertEqual(plist["SUFeedURL"] as? String,
                       "https://github.com/ilstar/github-panel/releases/latest/download/appcast.xml")
        XCTAssertEqual(plist["SUPublicEDKey"] as? String,
                       "/Dmysxg6JYobTDdz5ik0L96AsGykZNWcVamtzQQmii4=")
        XCTAssertTrue(plist["SUEnableAutomaticChecks"] as? Bool == true)
        XCTAssertTrue(plist["SUAutomaticallyUpdate"] as? Bool == true)
        XCTAssertTrue(plist["SUAllowsAutomaticUpdates"] as? Bool == true)
        XCTAssertTrue(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    }

    func testUpdateCheckUsesTheExistingApplicationMenu() throws {
        let source = try loadSourceFile("GithubPanel/GithubPanelApp.swift")

        XCTAssertTrue(source.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertFalse(source.contains("CommandMenu(\"GithubPanel\")"))
        XCTAssertTrue(source.contains("SettingsLink()"))
        XCTAssertTrue(source.contains(".commandsReplaced"))

        let settingsIndex = try XCTUnwrap(source.range(of: "SettingsLink()")?.lowerBound)
        let updateIndex = try XCTUnwrap(source.range(of: "Button(\"Check for Updates…\")")?.lowerBound)
        XCTAssertLessThan(settingsIndex, updateIndex)
    }

    private func loadInfoPlist() throws -> [String: Any] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repositoryRoot.appendingPathComponent("GithubPanel/Info.plist")
        let data = try Data(contentsOf: plistURL)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    private func loadSourceFile(_ path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }
}
