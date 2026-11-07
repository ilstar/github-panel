import XCTest
import GRDB
@testable import GithubPanel

final class LocalStoreTests: XCTestCase {
    func testMigrationsCreateTheTables() throws {
        let store = LocalStore.inMemory()

        try store.database.read { db in
            XCTAssertEqual(try LocalStore.migrator.appliedMigrations(db), ["createCaches"])
            XCTAssertEqual(try db.columns(in: "pull_request_list").map(\.name), ["kind", "rows", "savedAt"])
            XCTAssertEqual(try db.columns(in: "pull_request_detail").map(\.name), [
                "repoFullName", "number", "content", "comments", "commentLimits", "checks",
                "filesSinceLastReview", "lastUsedAt",
            ])
            XCTAssertEqual(try db.primaryKey("pull_request_detail").columns, ["repoFullName", "number"])
            XCTAssertEqual(try db.columns(in: "sync_state").map(\.name),
                           ["resource", "fetchedAt", "lastError", "lastAttemptAt"])
        }
    }

    func testMigratingAnUpToDateDatabaseKeepsItsRows() throws {
        let url = temporaryFileURL()
        saveAndClose(list(savedAt: 100, rows: ["a"]), at: url)

        let reopened = LocalStore.open(at: url)

        XCTAssertEqual(reopened.pullRequestList(.open, as: [String].self), list(savedAt: 100, rows: ["a"]))
    }

    func testAFileThatIsNotADatabaseIsReplaced() throws {
        let url = temporaryFileURL()
        try Data("not a database".utf8).write(to: url)

        saveAndClose(list(savedAt: 100, rows: ["a"]), at: url)

        XCTAssertEqual(LocalStore.open(at: url).pullRequestList(.open, as: [String].self),
                       list(savedAt: 100, rows: ["a"]))
    }

    func testADatabaseThatFailsToMigrateIsReplaced() throws {
        let url = temporaryFileURL()
        // A table the first migration creates, so running it fails.
        try DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "CREATE TABLE pull_request_list (other TEXT)")
        }

        let store = LocalStore.open(at: url)

        try store.database.read { db in
            XCTAssertEqual(try LocalStore.migrator.appliedMigrations(db), ["createCaches"])
            XCTAssertEqual(try db.columns(in: "pull_request_list").map(\.name), ["kind", "rows", "savedAt"])
        }
    }

    func testSavesListsByKind() {
        let store = LocalStore.inMemory()

        store.savePullRequestList(list(savedAt: 100, rows: ["mine"]), as: .open)
        store.savePullRequestList(list(savedAt: 200, rows: ["theirs"]), as: .reviewRequests)
        store.savePullRequestList(list(savedAt: 300, rows: ["newer"]), as: .open)

        XCTAssertEqual(store.pullRequestList(.open, as: [String].self), list(savedAt: 300, rows: ["newer"]))
        XCTAssertEqual(store.pullRequestList(.reviewRequests, as: [String].self), list(savedAt: 200, rows: ["theirs"]))

        store.removePullRequestLists()

        XCTAssertNil(store.pullRequestList(.open, as: [String].self))
        XCTAssertNil(store.pullRequestList(.reviewRequests, as: [String].self))
    }

    func testDefaultFileIsInApplicationSupport() throws {
        let url = try XCTUnwrap(LocalStore.defaultURL)

        XCTAssertEqual(url.lastPathComponent, "Store.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                       "Application Support")
    }

    private func saveAndClose(_ list: CachedPullRequestList<[String]>, at url: URL) {
        let store = LocalStore.open(at: url)
        store.savePullRequestList(list, as: .open)
        // Reads wait for earlier writes, so the list is in the file once this returns.
        XCTAssertEqual(store.pullRequestList(.open, as: [String].self), list)
    }

    private func list(savedAt: TimeInterval, rows: [String]) -> CachedPullRequestList<[String]> {
        CachedPullRequestList(savedAt: Date(timeIntervalSince1970: savedAt), rows: rows)
    }

    private func temporaryFileURL() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("Store.sqlite")
    }
}
