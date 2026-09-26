import XCTest
@testable import GithubPanel

final class FileTreeTests: XCTestCase {
    func testBuildsDirectoriesBeforeFilesAndJoinsSingleChildDirectories() {
        let rows = FileTree.rows(for: [
            "README.md",
            "Sources/App/Views/Main.swift",
            "Sources/App/Views/Detail.swift",
            "Sources/App/Model.swift",
            "Tests/AppTests/ModelTests.swift"
        ])

        XCTAssertEqual(rows, [
            FileTreeRow(id: "Sources/App", name: "Sources/App", depth: 0, kind: .directory),
            FileTreeRow(id: "Sources/App/Views", name: "Views", depth: 1, kind: .directory),
            FileTreeRow(id: "Sources/App/Views/Detail.swift", name: "Detail.swift", depth: 2, kind: .file),
            FileTreeRow(id: "Sources/App/Views/Main.swift", name: "Main.swift", depth: 2, kind: .file),
            FileTreeRow(id: "Sources/App/Model.swift", name: "Model.swift", depth: 1, kind: .file),
            FileTreeRow(id: "Tests/AppTests", name: "Tests/AppTests", depth: 0, kind: .directory),
            FileTreeRow(id: "Tests/AppTests/ModelTests.swift", name: "ModelTests.swift", depth: 1, kind: .file),
            FileTreeRow(id: "README.md", name: "README.md", depth: 0, kind: .file)
        ])
    }

    func testMatchesIgnoresCaseAndBlankQueries() {
        XCTAssertTrue(FileTree.matches("Sources/WidgetView.swift", query: "widgetview"))
        XCTAssertTrue(FileTree.matches("Sources/WidgetView.swift", query: "  "))
        XCTAssertTrue(FileTree.matches("Sources/WidgetView.swift", query: "sources/w"))
        XCTAssertFalse(FileTree.matches("Sources/WidgetView.swift", query: "legacy"))
    }

    func testVisibleRowsHideCollapsedDirectoryContents() {
        let rows = FileTree.rows(for: ["a/x.swift", "a/b/y.swift", "ab.swift"])

        let visible = FileTree.visibleRows(rows, collapsed: ["a"])

        XCTAssertEqual(visible.map(\.id), ["a", "ab.swift"])
        XCTAssertEqual(FileTree.visibleRows(rows, collapsed: []), rows)
    }
}
