import Foundation

enum TestPaths {
    /// The repository checkout, found relative to this file (GithubPanelTests/Support/TestPaths.swift)
    /// so tests in any subfolder resolve the same root.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func url(_ relativePath: String) -> URL {
        repositoryRoot.appendingPathComponent(relativePath)
    }
}
