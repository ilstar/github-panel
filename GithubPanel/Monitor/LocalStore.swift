import Foundation
import GRDB

/// The app's database: pull requests and lists as last loaded from GitHub, so they show right away.
/// Everything in it can be loaded again, so a file that can't be opened or migrated is deleted and started over.
final class LocalStore: Sendable {
    let database: DatabaseQueue

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
        return migrator
    }
}

// MARK: - Pull request lists

enum PullRequestListKind: String {
    case open
    case reviewRequests
}

extension LocalStore {
    /// Nil when nothing is saved or the saved list no longer decodes, such as after an update changed its shape.
    func pullRequestList<Rows>(_ kind: PullRequestListKind, as rows: Rows.Type = Rows.self)
        -> CachedPullRequestList<Rows>? {
        let row = try? database.read { db in
            try Row.fetchOne(db, sql: "SELECT rows, savedAt FROM pull_request_list WHERE kind = ?",
                             arguments: [kind.rawValue])
        }
        guard let row, let data: Data = row["rows"],
              let decoded = try? JSONDecoder().decode(Rows.self, from: data) else { return nil }
        return CachedPullRequestList(savedAt: Date(timeIntervalSince1970: row["savedAt"]), rows: decoded)
    }

    /// Saves off the calling thread. Reads made afterwards wait for it.
    func savePullRequestList<Rows>(_ list: CachedPullRequestList<Rows>, as kind: PullRequestListKind) {
        guard let data = try? JSONEncoder().encode(list.rows) else { return }
        let savedAt = list.savedAt.timeIntervalSince1970
        database.asyncWrite({ db in
            try db.execute(sql: "INSERT OR REPLACE INTO pull_request_list (kind, rows, savedAt) VALUES (?, ?, ?)",
                           arguments: [kind.rawValue, data, savedAt])
        }, completion: { _, _ in })
    }

    func removePullRequestLists() {
        database.asyncWrite({ db in
            try db.execute(sql: "DELETE FROM pull_request_list")
        }, completion: { _, _ in })
    }
}

// MARK: - Pull request details

extension LocalStore {
    struct SavedPullRequestDetail {
        var entry: PullRequestDetailCache.Entry
        var lastUsedAt: Date
    }

    /// What changed in the details cache since it last saved.
    struct PullRequestDetailChanges {
        var saved: [SavedPullRequestDetail] = []
        /// Entries only used, not changed, since the last save.
        var used: [PullRequestReference: Date] = [:]
        var removed: [PullRequestReference] = []
    }

    /// The saved details, least recently used first. Rows that no longer decode are left out.
    func pullRequestDetails() async -> [SavedPullRequestDetail] {
        let rows = (try? await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pull_request_detail ORDER BY lastUsedAt")
        }) ?? []
        return rows.compactMap { row in
            guard let entry = try? Self.detailEntry(from: row) else { return nil }
            return SavedPullRequestDetail(entry: entry, lastUsedAt: Date(timeIntervalSince1970: row["lastUsedAt"]))
        }
    }

    private static func detailEntry(from row: Row) throws -> PullRequestDetailCache.Entry {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ column: String) throws -> T? {
            guard let data: Data = row[column] else { return nil }
            return try decoder.decode(type, from: data)
        }
        guard let content = try decode(PullRequestDetailContent.self, "content"),
              let commentLimits = try decode(PullRequestCommentLimits.self, "commentLimits") else {
            throw DecodingError.valueNotFound(Data.self, .init(codingPath: [], debugDescription: "Missing blob"))
        }
        return PullRequestDetailCache.Entry(content: content,
                                            comments: try decode(PullRequestComments.self, "comments"),
                                            commentLimits: commentLimits,
                                            checks: try decode(PullRequestChecks.self, "checks"),
                                            filesSinceLastReview: try decode([PullRequestFile].self,
                                                                             "filesSinceLastReview"))
    }

    /// Writes the changes in one transaction, off the calling thread.
    func savePullRequestDetails(_ changes: PullRequestDetailChanges) async {
        let encoder = JSONEncoder()
        _ = try? await database.write { db in
            for saved in changes.saved {
                let entry = saved.entry
                let reference = entry.content.detail.reference
                guard let content = try? encoder.encode(entry.content),
                      let commentLimits = try? encoder.encode(entry.commentLimits) else { continue }
                try db.execute(sql: """
                    INSERT OR REPLACE INTO pull_request_detail
                        (repoFullName, number, content, comments, commentLimits, checks, filesSinceLastReview, lastUsedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        reference.repoFullName, reference.number, content,
                        entry.comments.flatMap { try? encoder.encode($0) }, commentLimits,
                        entry.checks.flatMap { try? encoder.encode($0) },
                        entry.filesSinceLastReview.flatMap { try? encoder.encode($0) },
                        saved.lastUsedAt.timeIntervalSince1970,
                    ])
            }
            for (reference, lastUsedAt) in changes.used {
                try db.execute(sql: """
                    UPDATE pull_request_detail SET lastUsedAt = ? WHERE repoFullName = ? AND number = ?
                    """, arguments: [lastUsedAt.timeIntervalSince1970, reference.repoFullName, reference.number])
            }
            for reference in changes.removed {
                try db.execute(sql: "DELETE FROM pull_request_detail WHERE repoFullName = ? AND number = ?",
                               arguments: [reference.repoFullName, reference.number])
            }
        }
    }

    func removeAllPullRequestDetails() async {
        _ = try? await database.write { db in
            try db.execute(sql: "DELETE FROM pull_request_detail")
        }
    }
}
