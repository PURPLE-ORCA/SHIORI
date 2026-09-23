import Foundation
import GRDB

/// The durable note record. Dates are stored as Unix epoch seconds so the
/// database remains portable and easy to inspect when debugging.
public struct Note: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "note"
    public static let colorCount = 20

    public let id: String
    public var title: String
    public var body: String
    public var colorIndex: Int
    public var attachedAppBundleIdentifier: String?
    public var pinned: Bool
    public let createdAt: Double
    public var updatedAt: Double
    public var sortIndex: Double
    public var archivedAt: Double?
    public var deletedAt: Double?
    public var doneAt: Double?

    public init(
        id: String = UUID().uuidString,
        title: String = "",
        body: String = "",
        colorIndex: Int = 0,
        pinned: Bool = false,
        createdAt: Double = Date().timeIntervalSince1970,
        updatedAt: Double? = nil,
        sortIndex: Double = 0,
        archivedAt: Double? = nil,
        doneAt: Double? = nil,
        deletedAt: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.colorIndex = min(max(colorIndex, 0), Note.colorCount - 1)
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.sortIndex = sortIndex
        self.archivedAt = archivedAt
        self.doneAt = doneAt
        self.deletedAt = deletedAt
    }
}

public enum NoteRepositoryError: LocalizedError, Equatable, Sendable {
    case noteNotFound(String)
    case invalidBackup
    case noteUnavailable

    public var errorDescription: String? {
        switch self {
        case let .noteNotFound(id): return "Note not found: \(id)"
        case .noteUnavailable: return "This note is no longer active. Its saved content has been preserved."
        case .invalidBackup: return "The backup did not pass SQLite integrity verification."
        }
    }
}

public final class NoteRepository: @unchecked Sendable {
    public let databaseURL: URL
    private let queue: DatabaseQueue

    private static let migrationID = "001_create_notes"

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.queue = try DatabaseQueue(path: databaseURL.path)
        try Self.migrate(queue)
    }

    /// Opens and migrates the database off the caller's actor.
    public static func open(at databaseURL: URL) async throws -> NoteRepository {
        try await Task.detached(priority: .userInitiated) {
            try NoteRepository(databaseURL: databaseURL)
        }.value
    }

    public static func defaultDatabaseURL(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "app.shiori.desktop"
    ) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("notes.sqlite")
    }

    private static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(migrationID) { db in
            try db.execute(sql: """
                CREATE TABLE note (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL DEFAULT '',
                    body TEXT NOT NULL DEFAULT '',
                    colorIndex INTEGER NOT NULL DEFAULT 0 CHECK (colorIndex BETWEEN 0 AND 4),
                    pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    sortIndex REAL NOT NULL DEFAULT 0,
                    archivedAt REAL,
                    doneAt REAL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_note_updatedAt ON note(updatedAt)")
            try db.execute(sql: "CREATE INDEX idx_note_pinned ON note(pinned)")
            try db.execute(sql: "CREATE INDEX idx_note_sortIndex ON note(sortIndex)")
            try db.execute(sql: "CREATE INDEX idx_note_archivedAt ON note(archivedAt)")
            try db.execute(sql: "CREATE INDEX idx_note_doneAt ON note(doneAt)")
        }
        migrator.registerMigration("002_soft_delete") { db in
            try db.execute(sql: "ALTER TABLE note ADD COLUMN deletedAt REAL")
        }
        migrator.registerMigration("003_app_attachment") { db in
            try db.execute(sql: "ALTER TABLE note ADD COLUMN attachedAppBundleIdentifier TEXT")
        }
        for (identifier, maximumColor) in [("004_ten_note_colors", 9), ("005_twenty_note_colors", 19)] {
            migrator.registerMigration(identifier) { db in
                try db.execute(sql: """
                    CREATE TABLE note_expanded (
                        id TEXT PRIMARY KEY NOT NULL,
                        title TEXT NOT NULL DEFAULT '',
                        body TEXT NOT NULL DEFAULT '',
                        colorIndex INTEGER NOT NULL DEFAULT 0 CHECK (colorIndex BETWEEN 0 AND \(maximumColor)),
                        pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0, 1)),
                        createdAt REAL NOT NULL,
                        updatedAt REAL NOT NULL,
                        sortIndex REAL NOT NULL DEFAULT 0,
                        archivedAt REAL,
                        doneAt REAL,
                        deletedAt REAL,
                        attachedAppBundleIdentifier TEXT
                    );
                    INSERT INTO note_expanded SELECT id, title, body, colorIndex, pinned, createdAt,
                        updatedAt, sortIndex, archivedAt, doneAt, deletedAt, attachedAppBundleIdentifier FROM note;
                    DROP TABLE note;
                    ALTER TABLE note_expanded RENAME TO note;
                    CREATE INDEX idx_note_updatedAt ON note(updatedAt);
                    CREATE INDEX idx_note_pinned ON note(pinned);
                    CREATE INDEX idx_note_sortIndex ON note(sortIndex);
                    CREATE INDEX idx_note_archivedAt ON note(archivedAt);
                    CREATE INDEX idx_note_doneAt ON note(doneAt);
                    """)
            }
        }
        try migrator.migrate(queue)
    }

    public func loadActiveNotes() async throws -> [Note] {
        try await queue.read { db in
            try Note.fetchAll(
                db,
                sql: "SELECT * FROM note WHERE deletedAt IS NULL AND archivedAt IS NULL ORDER BY sortIndex ASC, createdAt DESC"
            )
        }
    }

    public func loadArchivedNotes() async throws -> [Note] {
        try await queue.read { db in
            try Note.fetchAll(
                db,
                sql: "SELECT * FROM note WHERE deletedAt IS NULL AND archivedAt IS NOT NULL ORDER BY archivedAt DESC, updatedAt DESC"
            )
        }
    }

    public func loadAllNotes() async throws -> [Note] {
        try await queue.read { db in
            try Note.fetchAll(db, sql: "SELECT * FROM note WHERE deletedAt IS NULL ORDER BY archivedAt IS NOT NULL, sortIndex ASC, updatedAt DESC")
        }
    }

    public func search(_ query: String, archived: Bool? = nil) async throws -> [Note] {
        let normalized = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let candidates: [Note]
        switch archived {
        case true:
            candidates = try await loadArchivedNotes()
        case false:
            candidates = try await loadActiveNotes()
        case nil:
            candidates = try await loadAllNotes()
        }
        guard !normalized.isEmpty else { return candidates }
        return candidates.filter { note in
            note.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).localizedStandardContains(normalized)
                || note.body.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).localizedStandardContains(normalized)
        }
    }

    @discardableResult
    public func create() async throws -> Note {
        try await create(note: Note())
    }

    @discardableResult
    public func create(note: Note) async throws -> Note {
        try await queue.write { db in
            let firstSortIndex = try Double.fetchOne(
                db,
                sql: "SELECT MIN(sortIndex) FROM note WHERE deletedAt IS NULL AND archivedAt IS NULL"
            )
            var inserted = note
            inserted.sortIndex = (firstSortIndex ?? 0) - (firstSortIndex == nil ? 0 : 1)
            try inserted.insert(db)
            return inserted
        }
    }

    public func updateText(
        id: String,
        title: String,
        body: String,
        updatedAt: Double = Date().timeIntervalSince1970
    ) async throws {
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE note SET title = ?, body = ?, updatedAt = MAX(updatedAt, ?) WHERE id = ? AND archivedAt IS NULL AND deletedAt IS NULL",
                arguments: [title, body, updatedAt, id]
            )
            guard db.changesCount == 1 else { throw NoteRepositoryError.noteUnavailable }
        }
    }

    public func updateColor(id: String, colorIndex: Int, updatedAt: Double = Date().timeIntervalSince1970) async throws {
        let colorIndex = min(max(colorIndex, 0), Note.colorCount - 1)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE note SET colorIndex = ?, updatedAt = MAX(updatedAt, ?) WHERE id = ? AND archivedAt IS NULL AND deletedAt IS NULL",
                arguments: [colorIndex, updatedAt, id]
            )
            guard db.changesCount == 1 else { throw NoteRepositoryError.noteUnavailable }
        }
    }

    public func setAttachedApp(id: String, bundleIdentifier: String?) async throws {
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE note SET attachedAppBundleIdentifier = ?, pinned = CASE WHEN ? IS NULL THEN pinned ELSE 1 END WHERE id = ? AND archivedAt IS NULL AND deletedAt IS NULL",
                arguments: [bundleIdentifier, bundleIdentifier, id]
            )
            guard db.changesCount == 1 else { throw NoteRepositoryError.noteUnavailable }
        }
    }

    public func setPinned(id: String, pinned: Bool, updatedAt: Double = Date().timeIntervalSince1970) async throws {
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE note SET pinned = ?, updatedAt = MAX(updatedAt, ?) WHERE id = ? AND archivedAt IS NULL AND deletedAt IS NULL",
                arguments: [pinned, updatedAt, id]
            )
            guard db.changesCount == 1 else { throw NoteRepositoryError.noteUnavailable }
        }
    }

    public func reorder(ids: [String], updatedAt: Double = Date().timeIntervalSince1970) async throws {
        try await queue.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE note SET sortIndex = ?, updatedAt = MAX(updatedAt, ?) WHERE id = ? AND archivedAt IS NULL AND deletedAt IS NULL",
                    arguments: [Double(index), updatedAt, id]
                )
            }
        }
    }

    public func complete(id: String, body: String? = nil, updatedAt: Double = Date().timeIntervalSince1970) async throws {
        try await queue.write { db in
            let now = updatedAt
            if let body {
                try db.execute(
                    sql: """
                    UPDATE note
                    SET body = ?, archivedAt = ?, doneAt = ?, pinned = 0, updatedAt = MAX(updatedAt, ?)
                    WHERE id = ?
                    """,
                    arguments: [body, now, now, now, id]
                )
            } else {
                try db.execute(
                    sql: """
                    UPDATE note
                    SET archivedAt = ?, doneAt = ?, pinned = 0, updatedAt = MAX(updatedAt, ?)
                    WHERE id = ?
                    """,
                    arguments: [now, now, now, id]
                )
            }
            try Self.requireExistingRow(db, id: id)
        }
    }

    public func restore(id: String, updatedAt: Double = Date().timeIntervalSince1970) async throws {
        try await queue.write { db in
            let minSortIndex = try Double.fetchOne(
                db,
                sql: "SELECT MIN(sortIndex) FROM note WHERE deletedAt IS NULL AND archivedAt IS NULL"
            )
            try db.execute(
                sql: "UPDATE note SET archivedAt = NULL, doneAt = NULL, pinned = 0, sortIndex = ?, updatedAt = MAX(updatedAt, ?) WHERE id = ?",
                arguments: [(minSortIndex ?? 0) - (minSortIndex == nil ? 0 : 1), updatedAt, id]
            )
            try Self.requireExistingRow(db, id: id)
        }
    }

    public func setDeleted(id: String, deletedAt: Double?) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE note SET deletedAt = ? WHERE id = ? AND archivedAt IS NULL", arguments: [deletedAt, id])
            guard db.changesCount == 1 else { throw NoteRepositoryError.noteUnavailable }
        }
    }

    public func backup(in directory: URL) async throws -> URL {
        try await Task.detached(priority: .utility) { [queue] in
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            // Microseconds keep rapid explicit backups sortable; the random
            // suffix still prevents collisions from clocks with coarse ticks.
            let stamp = String(Int(Date().timeIntervalSince1970 * 1_000_000))
            let baseName = "notes-\(stamp)-\(UUID().uuidString.prefix(8))"
            let temporaryURL = directory.appendingPathComponent(".\(baseName).tmp.sqlite")
            let destinationURL = directory.appendingPathComponent("\(baseName).sqlite")
            defer { try? fileManager.removeItem(at: temporaryURL) }

            do {
                let destination = try DatabaseQueue(path: temporaryURL.path)
                try queue.backup(to: destination)
            }

            var readOnlyConfiguration = Configuration()
            readOnlyConfiguration.readonly = true
            let reopened = try DatabaseQueue(path: temporaryURL.path, configuration: readOnlyConfiguration)
            let isValid = try reopened.read { db in
                let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
                let count = try Note.fetchCount(db)
                return integrity == "ok" && count >= 0
            }
            guard isValid else { throw NoteRepositoryError.invalidBackup }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            try Self.pruneBackups(in: directory, keeping: 7, fileManager: fileManager)
            return destinationURL
        }.value
    }

    public func backupIfNeeded(in directory: URL) async throws -> URL? {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshots = try Self.snapshotURLs(in: directory, fileManager: fileManager)
        if let latest = snapshots.first,
           let modified = try latest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Calendar.current.isDateInToday(modified) {
            return nil
        }
        return try await backup(in: directory)
    }

    private static func requireExistingRow(_ db: Database, id: String) throws {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM note WHERE id = ?", arguments: [id]) != nil else {
            throw NoteRepositoryError.noteNotFound(id)
        }
    }

    private static func snapshotURLs(in directory: URL, fileManager: FileManager) throws -> [URL] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("notes-") }

        var dated: [(URL, Date)] = []
        dated.reserveCapacity(urls.count)
        for url in urls {
            let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            dated.append((url, date))
        }
        return dated
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.lastPathComponent > rhs.0.lastPathComponent : lhs.1 > rhs.1
            }
            .map(\.0)
    }

    private static func pruneBackups(in directory: URL, keeping count: Int, fileManager: FileManager) throws {
        let snapshots = try snapshotURLs(in: directory, fileManager: fileManager)
        for oldURL in snapshots.dropFirst(count) {
            try fileManager.removeItem(at: oldURL)
        }
    }
}
