import XCTest
import GRDB
@testable import GithubPanel

final class LocalStoreTests: XCTestCase {
    func testMigrationsCreateTheTables() throws {
        let store = LocalStore.inMemory()

        try store.database.read { db in
            XCTAssertEqual(try LocalStore.migrator.appliedMigrations(db), Self.migrations)
            XCTAssertEqual(try db.columns(in: "pull_request").map(\.name), [
                "repoFullName", "number", "headSHA", "checkState", "statusObservedAt",
                "openRow", "reviewRequestRow", "historyRow",
                "content", "comments", "commentLimits", "checks", "filesSinceLastReview", "detailUsedAt",
            ])
            XCTAssertEqual(try db.primaryKey("pull_request").columns, ["repoFullName", "number"])
            XCTAssertEqual(try db.columns(in: "pull_request_list").map(\.name), ["kind", "savedAt", "info"])
            XCTAssertEqual(try db.columns(in: "pull_request_list_member").map(\.name),
                           ["kind", "position", "reviewGroup", "repoFullName", "number"])
            XCTAssertFalse(try db.tableExists("pull_request_detail"))
            XCTAssertEqual(try db.columns(in: "pending_change").map(\.name), [
                "id", "repoFullName", "number", "kind", "payload", "createdAt", "state", "error", "postedCommentID",
            ])
            XCTAssertEqual(try db.primaryKey("pending_change").columns, ["id"])
            XCTAssertEqual(try db.columns(in: "sync_state").map(\.name),
                           ["resource", "fetchedAt", "lastError", "lastAttemptAt"])
        }
    }

    func testMigratingAnUpToDateDatabaseKeepsItsRows() throws {
        let url = temporaryFileURL()
        saveAndClose(openList(savedAt: 100, rows: [row(number: 1, status: .success)]), at: url)

        let reopened = LocalStore.open(at: url)

        XCTAssertEqual(reopened.pullRequestLists(), openList(savedAt: 100, rows: [row(number: 1, status: .success)]))
    }

    func testMigratingFromSeparateListsAndDetailsDropsThemAndKeepsPendingChanges() async throws {
        let url = temporaryFileURL()
        let database = try DatabaseQueue(path: url.path)
        try LocalStore.migrator.migrate(database, upTo: "addPostedCommentID")
        try await database.write { db in
            try db.execute(sql: "INSERT INTO pull_request_list (kind, rows, savedAt) VALUES ('open', ?, 100)",
                           arguments: [try JSONEncoder().encode(["a"])])
        }
        let change = PendingChange(reference: PullRequestReference(repoFullName: "acme/widgets", number: 1),
                                   kind: .title("Title"), createdAt: Date(timeIntervalSince1970: 1))
        await LocalStore.open(at: url).savePendingChanges([change])

        let store = LocalStore.open(at: url)

        XCTAssertEqual(store.pullRequestLists(), LocalStore.SavedPullRequestLists())
        let pending = await store.pendingChanges()
        XCTAssertEqual(pending, [change])
        try await store.database.read { db in
            XCTAssertEqual(try LocalStore.migrator.appliedMigrations(db), Self.migrations)
            XCTAssertFalse(try db.tableExists("pull_request_detail"))
        }
    }

    func testSavesPendingChangesOldestFirst() async {
        let store = LocalStore.inMemory()
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)
        // The first is failed, which a comment stays after a restart.
        let kinds: [PendingChange.Kind] = [
            .comment(.inline(body: "Why?", commitID: "abc", anchor: DiffCommentAnchor(path: "a.swift", line: 2, side: .left)),
                     authorLogin: "monalisa"),
            .title("Title"), .body("Body"), .fileViewed(pullRequestID: "PR", path: "a.swift", viewed: true),
            .threadResolved(threadID: "T", resolved: false), .reviewRequested(name: "acme/web", kind: .team, requested: true),
        ]
        let changes = kinds.enumerated().reversed().map { index, kind in
            PendingChange(reference: reference, kind: kind, createdAt: Date(timeIntervalSince1970: Double(index)),
                          state: index == 0 ? .failed : .pending, error: index == 0 ? "Nope" : nil)
        }
        await store.savePendingChanges(changes)
        await store.savePendingChanges([], removing: [changes[0].id])

        let saved = await store.pendingChanges()

        XCTAssertEqual(saved, Array(changes.dropFirst().reversed()))
    }

    func testAFileThatIsNotADatabaseIsReplaced() throws {
        let url = temporaryFileURL()
        try Data("not a database".utf8).write(to: url)

        saveAndClose(openList(savedAt: 100, rows: [row(number: 1, status: .success)]), at: url)

        XCTAssertEqual(LocalStore.open(at: url).pullRequestLists(),
                       openList(savedAt: 100, rows: [row(number: 1, status: .success)]))
    }

    func testADatabaseThatFailsToMigrateIsReplaced() throws {
        let url = temporaryFileURL()
        // A table the first migration creates, so running it fails.
        try DatabaseQueue(path: url.path).write { db in
            try db.execute(sql: "CREATE TABLE pull_request_list (other TEXT)")
        }

        let store = LocalStore.open(at: url)

        try store.database.read { db in
            XCTAssertEqual(try LocalStore.migrator.appliedMigrations(db), Self.migrations)
            XCTAssertEqual(try db.columns(in: "pull_request_list").map(\.name), ["kind", "savedAt", "info"])
        }
    }

    func testSavesOneRowPerPullRequestThatEveryListShares() throws {
        let store = LocalStore.inMemory()
        let shared = row(number: 1, status: .failure)
        let review = reviewRequestRow(number: 1)
        let reference = shared.reference
        var record = PullRequestRecord(openRow: shared, reviewRequestRow: review,
                                       status: shared.status(observedAt: Date(timeIntervalSince1970: 10)))
        store.savePullRequestList(list(savedAt: 100, members: [PullRequestListMember(reference: reference)]),
                                  as: .open, records: [reference: record])
        record.status = PullRequestStatus(headSHA: "new", checkState: nil, observedAt: Date(timeIntervalSince1970: 20))
        store.savePullRequestList(list(savedAt: 200, members: [PullRequestListMember(reference: reference,
                                                                                   reviewGroup: .fromMyTeams)]),
                                  as: .reviewRequests, records: [reference: record])

        let saved = store.pullRequestLists()

        XCTAssertEqual(saved.records, [reference: record])
        XCTAssertEqual(saved.lists[.open]?.members.map(\.reference), [reference])
        XCTAssertEqual(saved.lists[.reviewRequests]?.members.map(\.reviewGroup), [.fromMyTeams])
        XCTAssertEqual(saved.lists[.reviewRequests]?.savedAt, Date(timeIntervalSince1970: 200))
        try store.database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pull_request"), 1)
        }
    }

    func testSavingAStatusKeepsTheListsRows() {
        let store = LocalStore.inMemory()
        let open = row(number: 1, status: .failure)
        store.savePullRequestList(list(savedAt: 100, members: [PullRequestListMember(reference: open.reference)]),
                                  as: .open, records: [open.reference: PullRequestRecord(openRow: open)])
        let status = PullRequestStatus(headSHA: "new", checkState: .pending, observedAt: Date(timeIntervalSince1970: 5))

        store.savePullRequestStatus(status, for: open.reference)

        XCTAssertEqual(store.pullRequestLists().records[open.reference],
                       PullRequestRecord(openRow: open, status: status))
    }

    func testDetailsAndListsShareTheRowAndOnlyUnusedRowsAreDeleted() async throws {
        let store = LocalStore.inMemory()
        let listed = row(number: 1, status: .success)
        let detailOnly = PullRequestReference(repoFullName: "acme/widgets", number: 2)
        store.savePullRequestList(list(savedAt: 100, members: [PullRequestListMember(reference: listed.reference)]),
                                  as: .open, records: [listed.reference: PullRequestRecord(openRow: listed)])
        await store.savePullRequestDetails(LocalStore.PullRequestDetailChanges(saved: [
            detail(for: listed.reference), detail(for: detailOnly),
        ]))

        await store.removeAllPullRequestDetails()

        XCTAssertEqual(store.pullRequestLists().records[listed.reference], PullRequestRecord(openRow: listed),
                       "An explicit detail reset keeps the list's row")
        let details = await store.pullRequestDetails()
        XCTAssertTrue(details.isEmpty)
        try await store.database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pull_request"), 1)
        }

        store.removePullRequestLists()

        XCTAssertEqual(store.pullRequestLists(), LocalStore.SavedPullRequestLists())
        try await store.database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pull_request"), 0)
        }
    }

    func testListRefreshKeepsPreviouslyFetchedRowsAndDetailsInSQLite() async throws {
        let store = LocalStore.inMemory()
        let first = row(number: 1, status: .success)
        store.savePullRequestList(list(savedAt: 1, members: [PullRequestListMember(reference: first.reference)]),
                                  as: .open, records: [first.reference: PullRequestRecord(openRow: first)])
        store.savePullRequestList(list(savedAt: 2, members: []), as: .open, records: [:])
        XCTAssertEqual(store.pullRequestLists().open, [])
        try await store.database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pull_request"), 1)
        }
    }

    @MainActor
    func testDatabasePagesPreserveReviewGroupsAndExcludeHiddenRows() {
        let store = LocalStore.inMemory()
        let mine = (1...12).map { reviewRequestRow(number: $0) }
        let teams = (13...25).map { reviewRequestRow(number: $0) }
        let access = PullRequestCache(store: store)
        access.store(ReviewRequests(fromMe: mine, fromMyTeams: teams), fetchedAt: Date())

        let page = store.reviewRequestPage(2, excluding: [mine[0].id])
        XCTAssertEqual(page.rows.map(\.number), Array(12...21))
        XCTAssertEqual(page.fromMe.map(\.number), [12])
        XCTAssertEqual(page.fromMyTeams.map(\.number), Array(13...21))
        XCTAssertEqual(page.totalCount, 24)
        XCTAssertEqual(page.total(in: .fromMe), 11)
        XCTAssertEqual(page.total(in: .fromMyTeams), 13)
        XCTAssertEqual(page.rangeText, "11-20 of 24")
        XCTAssertEqual(store.reviewRequestPage(99, excluding: []).rows.map(\.number), Array(21...25))
    }

    @MainActor
    func testDatabaseReadsOnlyTheRequestedHistoryPage() {
        let store = LocalStore.inMemory()
        let access = PullRequestCache(store: store)
        for page in 1...3 {
            access.store(PullRequestHistoryPage(rows: [historyRow(number: page)], page: page, perPage: 1, totalCount: 3),
                         asPage: page, fetchedAt: Date())
        }

        let loaded = store.pullRequestLists(kinds: [.history(page: 2)])
        XCTAssertEqual(Set(loaded.lists.keys), [.history(page: 2)])
        XCTAssertEqual(Set(loaded.records.keys.map(\.number)), [2])
        XCTAssertEqual(loaded.historyPage(2)?.rows.map(\.number), [2])
        XCTAssertEqual(store.pullRequestLists().lists.count, 3, "Other pages remain stored")
    }

    func testRowsThatNoLongerDecodeAreLeftOut() async throws {
        let store = LocalStore.inMemory()
        let open = row(number: 1, status: .success)
        store.savePullRequestList(list(savedAt: 100, members: [PullRequestListMember(reference: open.reference)]),
                                  as: .open, records: [open.reference: PullRequestRecord(openRow: open)])
        try await store.database.write { db in
            try db.execute(sql: "UPDATE pull_request SET openRow = ?", arguments: [Data("{\"id\": 1}".utf8)])
        }

        XCTAssertEqual(store.pullRequestLists().records[open.reference], PullRequestRecord())
    }

    func testDefaultFileIsInApplicationSupport() throws {
        let url = try XCTUnwrap(LocalStore.defaultURL)

        XCTAssertEqual(url.lastPathComponent, "Store.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                       "Application Support")
    }

    private static let migrations = ["createCaches", "addPendingChanges", "addPostedCommentID", "pullRequestRecords"]

    private func saveAndClose(_ saved: LocalStore.SavedPullRequestLists, at url: URL) {
        let store = LocalStore.open(at: url)
        for (kind, list) in saved.lists {
            store.savePullRequestList(list, as: kind, records: saved.records)
        }
        // Reads wait for earlier writes, so the list is in the file once this returns.
        XCTAssertEqual(store.pullRequestLists(), saved)
    }

    private func openList(savedAt: TimeInterval, rows: [PullRequestRow]) -> LocalStore.SavedPullRequestLists {
        let records = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.reference, PullRequestRecord(openRow: $0, status: $0.status(observedAt: Date(timeIntervalSince1970: savedAt))))
        })
        return LocalStore.SavedPullRequestLists(
            lists: [.open: list(savedAt: savedAt, members: rows.map { PullRequestListMember(reference: $0.reference) })],
            records: records)
    }

    private func list(savedAt: TimeInterval, members: [PullRequestListMember]) -> LocalStore.SavedPullRequestList {
        LocalStore.SavedPullRequestList(savedAt: Date(timeIntervalSince1970: savedAt), info: PullRequestListInfo(),
                                        members: members)
    }

    private func detail(for reference: PullRequestReference) -> LocalStore.SavedPullRequestDetail {
        LocalStore.SavedPullRequestDetail(entry: PullRequestDetailEntry(content: detailContent(for: reference)),
                                          lastUsedAt: Date(timeIntervalSince1970: 1))
    }

    private func temporaryFileURL() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("Store.sqlite")
    }
}
