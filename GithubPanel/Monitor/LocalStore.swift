import Foundation
import GRDB

/// The app's database: one row per pull request with everything last loaded for it from GitHub, the lists that
/// hold them, and the changes the user made that GitHub hasn't confirmed yet. Everything but those changes can be
/// loaded again, so a file that can't be opened or migrated is deleted and started over.
final class LocalStore: Sendable {
    let database: DatabaseQueue

    /// Enqueues immediately so subsequent reads see the write. Encoding and disk I/O run on the database queue.
    private func enqueueWrite(_ updates: @escaping @Sendable (Database) throws -> Void) -> Task<Void, Never> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        database.asyncWrite(updates, completion: { _, _ in continuation.finish() })
        return Task { for await _ in stream {} }
    }

    /// Opens `database` and brings its tables up to date.
    init(database: DatabaseQueue) throws {
        try Self.migrator.migrate(database)
        self.database = database
    }

    /// A database that lasts as long as the store, for mock data and tests.
    static func inMemory() -> LocalStore {
        // An empty in-memory database has nothing that could fail to open or migrate.
        try! LocalStore(database: DatabaseQueue())
    }

    /// The store in the file at `url`. A file that can't be opened or migrated is deleted and created again,
    /// and if that fails too, the store lives in memory until the app quits.
    static func open(at url: URL) -> LocalStore {
        if let store = try? openFile(at: url) { return store }
        deleteFiles(at: url)
        return (try? openFile(at: url)) ?? inMemory()
    }

    /// The app's store in its Application Support folder, with the caches it replaced removed.
    static func openDefault() -> LocalStore {
        removeLegacyFiles()
        guard let url = defaultURL else { return inMemory() }
        return open(at: url)
    }

    static var defaultURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent("Store.sqlite")
    }

    /// The details cache used to be a JSON file in Caches. It's only a cache, so it's deleted rather than imported.
    static func removeLegacyFiles() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = caches.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("PullRequestDetails.json")
        try? FileManager.default.removeItem(at: url)
    }

    private static var folderName: String { Bundle.main.bundleIdentifier ?? "GithubPanel" }

    private static func openFile(at url: URL) throws -> LocalStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try LocalStore(database: DatabaseQueue(path: url.path))
    }

    private static func deleteFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// Every schema change, in order. Add a migration for a change rather than editing one that shipped.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createCaches") { db in
            try db.create(table: "pull_request_list") { t in
                t.primaryKey("kind", .text)
                t.column("rows", .blob).notNull()
                t.column("savedAt", .double).notNull()
            }
            try db.create(table: "pull_request_detail") { t in
                t.column("repoFullName", .text).notNull()
                t.column("number", .integer).notNull()
                t.column("content", .blob).notNull()
                t.column("comments", .blob)
                t.column("commentLimits", .blob).notNull()
                t.column("checks", .blob)
                t.column("filesSinceLastReview", .blob)
                t.column("lastUsedAt", .double).notNull().indexed()
                t.primaryKey(["repoFullName", "number"])
            }
            try db.create(table: "sync_state") { t in
                t.primaryKey("resource", .text)
                t.column("fetchedAt", .double)
                t.column("lastError", .text)
                t.column("lastAttemptAt", .double)
            }
        }
        migrator.registerMigration("addPendingChanges") { db in
            try db.create(table: "pending_change") { t in
                t.primaryKey("id", .text)
                t.column("repoFullName", .text).notNull()
                t.column("number", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("createdAt", .double).notNull()
                t.column("state", .text).notNull()
                t.column("error", .text)
            }
        }
        migrator.registerMigration("addPostedCommentID") { db in
            try db.alter(table: "pending_change") { t in
                t.add(column: "postedCommentID", .integer)
            }
        }
        migrator.registerMigration("pullRequestRecords") { db in
            // Lists and details were saved apart, so one pull request could show two states. Both are only caches,
            // so they're dropped rather than copied, and the next load fills one row per pull request.
            try db.drop(table: "pull_request_list")
            try db.drop(table: "pull_request_detail")
            try db.create(table: "pull_request") { t in
                t.column("repoFullName", .text).notNull()
                t.column("number", .integer).notNull()
                // The status every list shows, from the newest load. See `PullRequestStatus`.
                t.column("headSHA", .text)
                t.column("checkState", .text)
                t.column("statusObservedAt", .double)
                // The row each list's query returned.
                t.column("openRow", .blob)
                t.column("reviewRequestRow", .blob)
                t.column("historyRow", .blob)
                // The detail: null until it loads. Kept until an explicit account reset.
                t.column("content", .blob)
                t.column("comments", .blob)
                t.column("commentLimits", .blob)
                t.column("checks", .blob)
                t.column("filesSinceLastReview", .blob)
                t.column("detailUsedAt", .double).indexed()
                t.primaryKey(["repoFullName", "number"])
            }
            try db.create(table: "pull_request_list") { t in
                t.primaryKey("kind", .text)
                t.column("savedAt", .double).notNull()
                t.column("info", .blob).notNull()
            }
            try db.create(table: "pull_request_list_member") { t in
                t.column("kind", .text).notNull().references("pull_request_list", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("reviewGroup", .text)
                t.column("repoFullName", .text).notNull()
                t.column("number", .integer).notNull()
                t.primaryKey(["kind", "position"])
                t.foreignKey(["repoFullName", "number"], references: "pull_request")
            }
            try db.create(index: "pull_request_list_member_on_pull_request", on: "pull_request_list_member",
                          columns: ["repoFullName", "number"])
        }
        return migrator
    }
}

// MARK: - Pull requests

enum PullRequestListKind: Hashable {
    case open
    case history(page: Int)
    case reviewRequests

    /// The `pull_request_list` key, also used as the list's `sync_state` key.
    var key: String {
        switch self {
        case .open: return "open"
        case .history(let page): return "history:\(page)"
        case .reviewRequests: return "reviewRequests"
        }
    }

    init?(key: String) {
        switch key {
        case "open": self = .open
        case "reviewRequests": self = .reviewRequests
        default:
            let prefix = "history:"
            guard key.hasPrefix(prefix), let page = Int(key.dropFirst(prefix.count)) else { return nil }
            self = .history(page: page)
        }
    }
}

extension ReviewRequestGroup {
    /// The `pull_request_list_member.reviewGroup` value.
    var key: String {
        switch self {
        case .fromMe: return "fromMe"
        case .fromMyTeams: return "fromMyTeams"
        }
    }

    init?(key: String) {
        guard let group = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = group
    }
}

extension LocalStore {
    struct SavedPullRequestList: Equatable {
        /// When GitHub returned the list.
        var savedAt: Date
        var info: PullRequestListInfo
        var members: [PullRequestListMember]
    }

    struct SavedPullRequestLists: Equatable {
        var lists: [PullRequestListKind: SavedPullRequestList] = [:]
        /// The pull requests the lists hold.
        var records: [PullRequestReference: PullRequestRecord] = [:]

        var open: [PullRequestRow]? {
            PullRequestListRows.open(lists[.open]?.members, records: records)
        }

        var reviewRequests: ReviewRequests? {
            PullRequestListRows.reviewRequests(lists[.reviewRequests]?.members, info: lists[.reviewRequests]?.info,
                                               records: records)
        }

        func historyPage(_ page: Int) -> PullRequestHistoryPage? {
            PullRequestListRows.historyPage(page, members: lists[.history(page: page)]?.members,
                                            info: lists[.history(page: page)]?.info, records: records)
        }
    }

    /// The saved lists and their pull requests, read on the calling thread so they show as soon as the app starts.
    /// Lists and rows that no longer decode, such as after an update changed their shape, are left out. Writes
    /// queued before the call land first, since the database runs reads and writes in order.
    func pullRequestLists(kinds: Set<PullRequestListKind>? = nil) -> SavedPullRequestLists {
        (try? database.read { try Self.pullRequestLists(in: $0, kinds: kinds) }) ?? SavedPullRequestLists()
    }

    /// Reads one list page. Details are never selected, and old History pages stay solely in SQLite.
    func openPullRequestPage(_ page: Int, size: Int) -> (rows: [PullRequestRow], page: Int, total: Int) {
        let size = max(1, size)
        if let pagination = pullRequestListInfo(.open)?.pagination {
            return (pullRequestLists(kinds: [.open]).open ?? [], pagination.request.page, pagination.totalCount)
        }
        return (try? database.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pull_request_list_member WHERE kind = ?",
                                         arguments: [PullRequestListKind.open.key]) ?? 0
            let page = min(max(1, page), max(1, (total + size - 1) / size))
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.repoFullName, p.number, p.openRow, p.reviewRequestRow, p.historyRow,
                       p.headSHA, p.checkState, p.statusObservedAt
                FROM pull_request_list_member m JOIN pull_request p USING (repoFullName, number)
                WHERE m.kind = ? ORDER BY m.position LIMIT ? OFFSET ?
                """, arguments: [PullRequestListKind.open.key, size, (page - 1) * size])
            return (rows.compactMap { Self.record(from: $0, decoder: JSONDecoder()).shownOpenRow }, page, total)
        }) ?? ([], 1, 0)
    }

    func reviewRequestPage(_ requestedPage: Int, excluding hidden: Set<String>) -> ReviewRequestsPage {
        if let pagination = pullRequestListInfo(.reviewRequests)?.pagination {
            let requests = pullRequestLists(kinds: [.reviewRequests]).reviewRequests ?? .empty
            let visible = requests.removing { hidden.contains($0.id) }
            return ReviewRequestsPage(loaded: visible, page: pagination.request.page,
                                      fromMeTotal: max(0, (pagination.fromMeTotal ?? 0) - requests.fromMe.count + visible.fromMe.count),
                                      fromMyTeamsTotal: max(0, (pagination.fromMyTeamsTotal ?? 0) - requests.fromMyTeams.count + visible.fromMyTeams.count))
        }
        return (try? database.read { db in
            let hiddenIDs = Array(hidden)
            let placeholders = hiddenIDs.map { _ in "?" }.joined(separator: ",")
            let filter = hidden.isEmpty ? "" : " AND (m.repoFullName || '#' || m.number) NOT IN (\(placeholders))"
            let arguments = StatementArguments([PullRequestListKind.reviewRequests.key] + hiddenIDs)
            let counts = try Row.fetchAll(db, sql: """
                SELECT m.reviewGroup, COUNT(*) AS count FROM pull_request_list_member m
                WHERE m.kind = ?\(filter) GROUP BY m.reviewGroup
                """, arguments: arguments)
            let fromMe = counts.first { ($0["reviewGroup"] as String?) == ReviewRequestGroup.fromMe.key }?["count"] as Int? ?? 0
            let fromTeams = counts.first { ($0["reviewGroup"] as String?) == ReviewRequestGroup.fromMyTeams.key }?["count"] as Int? ?? 0
            let size = ReviewRequestsPage.defaultSize
            let page = min(max(1, requestedPage), max(1, (fromMe + fromTeams + size - 1) / size))
            var pageArguments = arguments
            pageArguments += StatementArguments([size, (page - 1) * size])
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.repoFullName, p.number, p.openRow, p.reviewRequestRow, p.historyRow,
                       p.headSHA, p.checkState, p.statusObservedAt, m.reviewGroup
                FROM pull_request_list_member m JOIN pull_request p USING (repoFullName, number)
                WHERE m.kind = ?\(filter) ORDER BY m.position LIMIT ? OFFSET ?
                """, arguments: pageArguments)
            func group(_ group: ReviewRequestGroup) -> [ReviewRequestRow] {
                rows.filter { ($0["reviewGroup"] as String?) == group.key }
                    .compactMap { Self.record(from: $0, decoder: JSONDecoder()).shownReviewRequestRow }
            }
            return ReviewRequestsPage(loaded: ReviewRequests(fromMe: group(.fromMe), fromMyTeams: group(.fromMyTeams)),
                                      page: page, fromMeTotal: fromMe, fromMyTeamsTotal: fromTeams)
        }) ?? ReviewRequestsPage(requests: .empty, page: 1)
    }

    /// Lightweight IDs support keyboard and notification navigation without keeping off-page PR rows in memory.
    func pullRequestIDs(in kind: PullRequestListKind, excluding hidden: Set<String> = []) -> [String] {
        (try? database.read { db in
            try String.fetchAll(db, sql: """
                SELECT repoFullName || '#' || number FROM pull_request_list_member WHERE kind = ? ORDER BY position
                """, arguments: [kind.key]).filter { !hidden.contains($0) }
        }) ?? []
    }

    func reviewRequest(_ reference: PullRequestReference) -> ReviewRequestRow? {
        try? database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.repoFullName, p.number, p.openRow, p.reviewRequestRow, p.historyRow,
                       p.headSHA, p.checkState, p.statusObservedAt
                FROM pull_request p JOIN pull_request_list_member m USING (repoFullName, number)
                WHERE m.kind = ? AND p.repoFullName = ? AND p.number = ?
                """, arguments: [PullRequestListKind.reviewRequests.key, reference.repoFullName, reference.number]) else { return nil }
            return Self.record(from: row, decoder: JSONDecoder()).shownReviewRequestRow
        }
    }

    func pullRequestListSavedAt(_ kind: PullRequestListKind) -> Date? {
        try? database.read { db in
            try Double.fetchOne(db, sql: "SELECT savedAt FROM pull_request_list WHERE kind = ?",
                                arguments: [kind.key]).map(Date.init(timeIntervalSince1970:))
        }
    }

    func pullRequestListInfo(_ kind: PullRequestListKind) -> PullRequestListInfo? {
        try? database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT info FROM pull_request_list WHERE kind = ?",
                                               arguments: [kind.key]) else { return nil }
            return try JSONDecoder().decode(PullRequestListInfo.self, from: data)
        }
    }

    func holdsPullRequestList(_ kind: PullRequestListKind) -> Bool {
        (try? database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pull_request_list WHERE kind = ?)",
                              arguments: [kind.key]) ?? false
        }) ?? false
    }

    func listKinds(overlapping kind: PullRequestListKind) -> [PullRequestListKind] {
        (try? database.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT other.kind FROM pull_request_list_member m
                JOIN pull_request_list_member other USING (repoFullName, number)
                WHERE m.kind = ? AND other.kind != ?
                """, arguments: [kind.key, kind.key]).compactMap(PullRequestListKind.init(key:))
        }) ?? []
    }

    func listKinds(containing reference: PullRequestReference) -> [PullRequestListKind] {
        (try? database.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT kind FROM pull_request_list_member WHERE repoFullName = ? AND number = ?
                """, arguments: [reference.repoFullName, reference.number]).compactMap(PullRequestListKind.init(key:))
        }) ?? []
    }

    func removeOpenPullRequest(_ reference: PullRequestReference) {
        database.asyncWrite({ db in
            try db.execute(sql: """
                DELETE FROM pull_request_list_member WHERE kind = ? AND repoFullName = ? AND number = ?
                """, arguments: [PullRequestListKind.open.key, reference.repoFullName, reference.number])
        }, completion: { _, _ in })
    }

    /// Calls `onChange` on the main queue after each write that changes the saved lists or their rows, whichever
    /// code made it. Observing stops when the returned value is cancelled or released.
    func observePullRequestListChanges(onChange: @escaping @MainActor () -> Void) -> AnyDatabaseCancellable {
        let rows = SQLRequest<Row>(sql: """
            SELECT headSHA, checkState, statusObservedAt, openRow, reviewRequestRow, historyRow FROM pull_request
            """)
        return DatabaseRegionObservation(tracking: Table("pull_request_list"), Table("pull_request_list_member"), rows)
            .start(in: database, onError: { _ in }, onChange: { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { onChange() } }
            })
    }

    private static func pullRequestLists(in db: Database, kinds: Set<PullRequestListKind>?) throws -> SavedPullRequestLists {
        let keys = kinds?.map(\.key) ?? []
        let placeholders = keys.map { _ in "?" }.joined(separator: ",")
        let filter = kinds == nil ? "" : " WHERE kind IN (\(placeholders))"
        let memberFilter = kinds == nil ? "" : " AND m.kind IN (\(placeholders))"
        let arguments = StatementArguments(keys)
        let decoder = JSONDecoder()
        var saved = SavedPullRequestLists()
        var members: [PullRequestListKind: [PullRequestListMember]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT kind, reviewGroup, repoFullName, number FROM pull_request_list_member\(filter) ORDER BY kind, position
            """, arguments: arguments) {
            guard let kind = PullRequestListKind(key: row["kind"] as String) else { continue }
            let reference = PullRequestReference(repoFullName: row["repoFullName"], number: row["number"])
            let group = (row["reviewGroup"] as String?).flatMap(ReviewRequestGroup.init(key:))
            members[kind, default: []].append(PullRequestListMember(reference: reference, reviewGroup: group))
        }
        for row in try Row.fetchAll(db, sql: "SELECT kind, savedAt, info FROM pull_request_list\(filter)", arguments: arguments) {
            guard let kind = PullRequestListKind(key: row["kind"] as String), let data: Data = row["info"],
                  let info = try? decoder.decode(PullRequestListInfo.self, from: data) else { continue }
            saved.lists[kind] = SavedPullRequestList(savedAt: Date(timeIntervalSince1970: row["savedAt"]),
                                                     info: info, members: members[kind] ?? [])
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT repoFullName, number, headSHA, checkState, statusObservedAt, openRow, reviewRequestRow, historyRow
            FROM pull_request
            WHERE EXISTS (SELECT 1 FROM pull_request_list_member m
                          WHERE m.repoFullName = pull_request.repoFullName AND m.number = pull_request.number\(memberFilter))
            """, arguments: arguments) {
            let reference = PullRequestReference(repoFullName: row["repoFullName"], number: row["number"])
            saved.records[reference] = Self.record(from: row, decoder: decoder)
        }
        return saved
    }

    private static func record(from row: Row, decoder: JSONDecoder) -> PullRequestRecord {
        func decode<T: Decodable>(_ type: T.Type, _ column: String) -> T? {
            (row[column] as Data?).flatMap { try? decoder.decode(type, from: $0) }
        }
        var record = PullRequestRecord(openRow: decode(PullRequestRow.self, "openRow"),
                                       reviewRequestRow: decode(ReviewRequestRow.self, "reviewRequestRow"),
                                       historyRow: decode(PullRequestHistoryRow.self, "historyRow"))
        if let headSHA: String = row["headSHA"], let observedAt: Double = row["statusObservedAt"] {
            record.status = PullRequestStatus(headSHA: headSHA,
                                              checkState: (row["checkState"] as String?).flatMap(CheckState.init),
                                              observedAt: Date(timeIntervalSince1970: observedAt))
        }
        return record
    }

    /// Saves list membership and fetched rows in one transaction off the calling thread. Previously fetched PRs
    /// remain in SQLite after leaving a list. Reads made afterwards wait for this write.
    func savePullRequestList(_ list: SavedPullRequestList, as kind: PullRequestListKind,
                             records: [PullRequestReference: PullRequestRecord]) {
        let encoder = JSONEncoder()
        guard let info = try? encoder.encode(list.info) else { return }
        let rows = records.map { reference, record in
            (reference: reference, status: record.status,
             open: record.openRow.flatMap { try? encoder.encode($0) },
             reviewRequest: record.reviewRequestRow.flatMap { try? encoder.encode($0) },
             history: record.historyRow.flatMap { try? encoder.encode($0) })
        }
        database.asyncWrite({ db in
            for row in rows {
                let reference = row.reference
                try db.execute(sql: """
                    INSERT INTO pull_request (repoFullName, number, openRow, reviewRequestRow, historyRow)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(repoFullName, number) DO UPDATE SET
                        openRow = COALESCE(excluded.openRow, openRow),
                        reviewRequestRow = COALESCE(excluded.reviewRequestRow, reviewRequestRow),
                        historyRow = COALESCE(excluded.historyRow, historyRow)
                    """, arguments: [reference.repoFullName, reference.number, row.open, row.reviewRequest, row.history])
                try Self.saveStatus(row.status, for: reference, in: db)
            }
            try db.execute(sql: "DELETE FROM pull_request_list_member WHERE kind = ?", arguments: [kind.key])
            try db.execute(sql: """
                INSERT INTO pull_request_list (kind, savedAt, info) VALUES (?, ?, ?)
                ON CONFLICT(kind) DO UPDATE SET savedAt = excluded.savedAt, info = excluded.info
                """, arguments: [kind.key, list.savedAt.timeIntervalSince1970, info])
            for (position, member) in list.members.enumerated() {
                try db.execute(sql: """
                    INSERT INTO pull_request_list_member (kind, position, reviewGroup, repoFullName, number)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [kind.key, position, member.reviewGroup?.key,
                                     member.reference.repoFullName, member.reference.number])
            }
        }, completion: { _, _ in })
    }

    /// Saves a status seen by a detail or checks load, off the calling thread.
    func savePullRequestStatus(_ status: PullRequestStatus, for reference: PullRequestReference) {
        database.asyncWrite({ db in
            try db.execute(sql: "INSERT OR IGNORE INTO pull_request (repoFullName, number) VALUES (?, ?)",
                           arguments: [reference.repoFullName, reference.number])
            try Self.saveStatus(status, for: reference, in: db)
        }, completion: { _, _ in })
    }

    private static func saveStatus(_ status: PullRequestStatus?, for reference: PullRequestReference,
                                   in db: Database) throws {
        guard let incoming = status else { return }
        let current = try Row.fetchOne(db, sql: """
            SELECT headSHA, checkState, statusObservedAt FROM pull_request WHERE repoFullName = ? AND number = ?
            """, arguments: [reference.repoFullName, reference.number])
        var status = incoming
        if let current, let head: String = current["headSHA"], let observedAt: Double = current["statusObservedAt"] {
            status = PullRequestStatus(headSHA: head,
                checkState: (current["checkState"] as String?).flatMap(CheckState.init),
                observedAt: Date(timeIntervalSince1970: observedAt)).merging(incoming)
        }
        try db.execute(sql: """
            UPDATE pull_request SET headSHA = ?, checkState = ?, statusObservedAt = ?
            WHERE repoFullName = ? AND number = ?
            """, arguments: [status.headSHA, status.checkState?.rawValue, status.observedAt.timeIntervalSince1970,
                             reference.repoFullName, reference.number])
    }

    func removePullRequestLists() {
        database.asyncWrite({ db in
            try db.execute(sql: "DELETE FROM pull_request_list_member")
            try db.execute(sql: "DELETE FROM pull_request_list")
            try db.execute(sql: """
                UPDATE pull_request SET openRow = NULL, reviewRequestRow = NULL, historyRow = NULL,
                    headSHA = NULL, checkState = NULL, statusObservedAt = NULL
                """)
            try Self.deleteUnusedPullRequests(in: db)
        }, completion: { _, _ in })
    }

    /// Deletes pull requests that no list holds and whose detail isn't cached.
    private static func deleteUnusedPullRequests(in db: Database) throws {
        try db.execute(sql: """
            DELETE FROM pull_request
            WHERE content IS NULL
              AND NOT EXISTS (SELECT 1 FROM pull_request_list_member m
                              WHERE m.repoFullName = pull_request.repoFullName AND m.number = pull_request.number)
            """)
    }
}

// MARK: - Pull request details

extension LocalStore {
    struct SavedPullRequestDetail {
        var entry: PullRequestDetailEntry
        var lastUsedAt: Date
    }

    /// Details to persist, optionally confirming pending edits in the same transaction.
    struct PullRequestDetailChanges {
        var saved: [SavedPullRequestDetail] = []
        /// Pending changes GitHub confirmed, deleted in the same transaction that saves what it returned.
        var confirmed: [UUID] = []
    }

    /// Reads only the selected PR, without restoring other details into UI memory.
    func pullRequestDetail(_ reference: PullRequestReference) -> PullRequestDetailEntry? {
        try? database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT content, comments, commentLimits, checks, filesSinceLastReview FROM pull_request
                WHERE repoFullName = ? AND number = ? AND content IS NOT NULL
                """, arguments: [reference.repoFullName, reference.number]) else { return nil }
            return try Self.detailEntry(from: row)
        }
    }

    var pullRequestDetailCount: Int {
        (try? database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pull_request WHERE content IS NOT NULL") ?? 0
        }) ?? 0
    }

    func enqueueRemoveDetailsAndChanges() -> Task<Void, Never> {
        enqueueWrite { db in
            try db.execute(sql: Self.clearDetailSQL)
            try db.execute(sql: "DELETE FROM pending_change")
            try Self.deleteUnusedPullRequests(in: db)
        }
    }

    /// All saved details, for inspection and tests. The UI reads individual PRs instead.
    func pullRequestDetails() async -> [SavedPullRequestDetail] {
        let rows = (try? await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pull_request WHERE content IS NOT NULL ORDER BY detailUsedAt")
        }) ?? []
        return rows.compactMap { row in
            guard let entry = try? Self.detailEntry(from: row) else { return nil }
            return SavedPullRequestDetail(entry: entry, lastUsedAt: Date(timeIntervalSince1970: row["detailUsedAt"]))
        }
    }

    private static func detailEntry(from row: Row) throws -> PullRequestDetailEntry {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ column: String) throws -> T? {
            guard let data: Data = row[column] else { return nil }
            return try decoder.decode(type, from: data)
        }
        guard let content = try decode(PullRequestDetailContent.self, "content"),
              let commentLimits = try decode(PullRequestCommentLimits.self, "commentLimits") else {
            throw DecodingError.valueNotFound(Data.self, .init(codingPath: [], debugDescription: "Missing blob"))
        }
        return PullRequestDetailEntry(content: content,
                                            comments: try decode(PullRequestComments.self, "comments"),
                                            commentLimits: commentLimits,
                                            checks: try decode(PullRequestChecks.self, "checks"),
                                            filesSinceLastReview: try decode([PullRequestFile].self,
                                                                             "filesSinceLastReview"))
    }

    /// Writes the changes in one transaction, off the calling thread. Only the detail columns change, so the lists'
    /// rows and status for the same pull request stay.
    func savePullRequestDetails(_ changes: PullRequestDetailChanges) async {
        await enqueuePullRequestDetails(changes).value
    }

    func enqueuePullRequestDetails(_ changes: PullRequestDetailChanges) -> Task<Void, Never> {
        enqueueWrite { db in
            let encoder = JSONEncoder()
            for saved in changes.saved {
                let entry = saved.entry
                let reference = entry.content.detail.reference
                guard let content = try? encoder.encode(entry.content),
                      let commentLimits = try? encoder.encode(entry.commentLimits) else { continue }
                try db.execute(sql: """
                    INSERT INTO pull_request
                        (repoFullName, number, content, comments, commentLimits, checks, filesSinceLastReview, detailUsedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(repoFullName, number) DO UPDATE SET
                        content = excluded.content,
                        comments = excluded.comments,
                        commentLimits = excluded.commentLimits,
                        checks = excluded.checks,
                        filesSinceLastReview = excluded.filesSinceLastReview,
                        detailUsedAt = excluded.detailUsedAt
                    """, arguments: [
                        reference.repoFullName, reference.number, content,
                        entry.comments.flatMap { try? encoder.encode($0) }, commentLimits,
                        entry.checks.flatMap { try? encoder.encode($0) },
                        entry.filesSinceLastReview.flatMap { try? encoder.encode($0) },
                        saved.lastUsedAt.timeIntervalSince1970,
                    ])
            }
            for id in changes.confirmed {
                try db.execute(sql: "DELETE FROM pending_change WHERE id = ?", arguments: [id.uuidString])
            }
        }
    }

    func removeAllPullRequestDetails() async {
        _ = try? await database.write { db in
            try db.execute(sql: Self.clearDetailSQL)
            try Self.deleteUnusedPullRequests(in: db)
        }
    }

    private static let clearDetailSQL = """
        UPDATE pull_request SET content = NULL, comments = NULL, commentLimits = NULL, checks = NULL,
            filesSinceLastReview = NULL, detailUsedAt = NULL
        """
}

// MARK: - Pending changes

extension LocalStore {
    /// The saved changes, oldest first. Ones that were sending when the app quit are pending again when sending them
    /// twice is safe. Comments and reviews that were waiting or sending fail instead, since one may have posted, and
    /// ones GitHub posted or started are dropped, since the next load shows them. Rows that no longer decode are left out.
    func pendingChanges() async -> [PendingChange] {
        (try? await database.write { db -> [PendingChange] in
            var changes: [PendingChange] = []
            for row in try Row.fetchAll(db, sql: "SELECT * FROM pending_change ORDER BY createdAt") {
                guard let saved = Self.pendingChange(from: row) else { continue }
                var change = saved
                if change.wasPosted {
                    try db.execute(sql: "DELETE FROM pending_change WHERE id = ?", arguments: [change.id.uuidString])
                    continue
                }
                if change.state != .failed, !change.kind.isSafeToResend {
                    change.state = .failed
                    change.error = PendingChange.notSentAfterQuitError
                } else if change.state == .sending {
                    change.state = .pending
                }
                if change != saved {
                    try db.execute(sql: "UPDATE pending_change SET state = ?, error = ? WHERE id = ?",
                                   arguments: [change.state.rawValue, change.error, change.id.uuidString])
                }
                changes.append(change)
            }
            return changes
        }) ?? []
    }

    private static func pendingChange(from row: Row) -> PendingChange? {
        guard let id = UUID(uuidString: row["id"]), let payload: Data = row["payload"],
              let kind = try? JSONDecoder().decode(PendingChange.Kind.self, from: payload),
              let state = PendingChange.State(rawValue: row["state"] as String) else { return nil }
        return PendingChange(id: id, reference: PullRequestReference(repoFullName: row["repoFullName"],
                                                                     number: row["number"]),
                             kind: kind, createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                             state: state, error: row["error"], postedCommentID: row["postedCommentID"])
    }

    /// Inserts or replaces each change, and deletes the ones in `removed`, in one transaction.
    func savePendingChanges(_ changes: [PendingChange], removing removed: [UUID] = []) async {
        await enqueuePendingChanges(changes, removing: removed).value
    }

    func enqueuePendingChanges(_ changes: [PendingChange], removing removed: [UUID] = []) -> Task<Void, Never> {
        enqueueWrite { db in
            let encoder = JSONEncoder()
            for id in removed {
                try db.execute(sql: "DELETE FROM pending_change WHERE id = ?", arguments: [id.uuidString])
            }
            for change in changes {
                guard let payload = try? encoder.encode(change.kind) else { continue }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO pending_change
                        (id, repoFullName, number, kind, payload, createdAt, state, error, postedCommentID)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        change.id.uuidString, change.reference.repoFullName, change.reference.number,
                        change.kind.name, payload, change.createdAt.timeIntervalSince1970,
                        change.state.rawValue, change.error, change.postedCommentID,
                    ])
            }
        }
    }

    func removeAllPendingChanges() async {
        _ = try? await database.write { db in
            try db.execute(sql: "DELETE FROM pending_change")
        }
    }
}

// MARK: - Sync state

extension LocalStore {
    struct SyncState: Equatable {
        var fetchedAt: Date?
        var lastAttemptAt: Date?
        var lastError: String?
    }

    func syncState(for resource: String) async -> SyncState? {
        try? await database.read { db in try Self.syncState(for: resource, in: db) }
    }

    /// Reads on the calling thread, for showing saved lists as soon as the app starts.
    func syncStateNow(for resource: String) -> SyncState? {
        try? database.read { db in try Self.syncState(for: resource, in: db) }
    }

    private static func syncState(for resource: String, in db: Database) throws -> SyncState? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_state WHERE resource = ?",
                                         arguments: [resource]) else { return nil }
        return SyncState(fetchedAt: (row["fetchedAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                         lastAttemptAt: (row["lastAttemptAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
                         lastError: row["lastError"])
    }

    /// Records an attempt to load `resource`. A failed attempt keeps the last `fetchedAt`.
    func recordSync(for resource: String, attemptedAt: Date, fetchedAt: Date? = nil, error: String? = nil) async {
        _ = try? await database.write { db in
            try db.execute(sql: """
                INSERT INTO sync_state (resource, fetchedAt, lastError, lastAttemptAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(resource) DO UPDATE SET
                    fetchedAt = COALESCE(excluded.fetchedAt, fetchedAt),
                    lastError = excluded.lastError,
                    lastAttemptAt = excluded.lastAttemptAt
                """, arguments: [resource, fetchedAt?.timeIntervalSince1970, error, attemptedAt.timeIntervalSince1970])
        }
    }

    func removeSyncStates() async {
        _ = try? await database.write { db in
            try db.execute(sql: "DELETE FROM sync_state")
        }
    }
}
