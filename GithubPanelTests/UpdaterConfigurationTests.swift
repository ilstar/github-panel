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
}
