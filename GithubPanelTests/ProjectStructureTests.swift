import Foundation
import XCTest

final class ProjectStructureTests: XCTestCase {
    func testTargetsUseSynchronizedFolders() throws {
        let project = try loadProjectFile()

        XCTAssertTrue(project.contains("path = GithubPanel;\n\t\t\tsourceTree = \"<group>\";"))
        XCTAssertTrue(project.contains("path = GithubPanelTests;\n\t\t\tsourceTree = \"<group>\";"))
        XCTAssertEqual(project.components(separatedBy: "isa = PBXFileSystemSynchronizedRootGroup;").count - 1, 2)
    }

    func testProjectDoesNotListIndividualSourceFiles() throws {
        let project = try loadProjectFile()

        XCTAssertFalse(project.contains("lastKnownFileType = sourcecode.swift"))
        XCTAssertFalse(project.contains(".swift in Sources"))
    }

    func testInfoPlistIsExcludedFromAppResources() throws {
        let project = try loadProjectFile()

        XCTAssertTrue(project.contains("isa = PBXFileSystemSynchronizedBuildFileExceptionSet;"))
        XCTAssertTrue(project.contains("membershipExceptions = (\n\t\t\t\tInfo.plist,\n\t\t\t);"))
    }

    private func loadProjectFile() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectURL = repositoryRoot.appendingPathComponent("GithubPanel.xcodeproj/project.pbxproj")
        return try String(contentsOf: projectURL, encoding: .utf8)
    }
}
