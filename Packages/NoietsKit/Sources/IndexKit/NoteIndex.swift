import Foundation
import GRDB
import VaultStore
import CryptoKit

/// The SQLite/FTS5 index — a fully rebuildable derived cache. Files on disk
/// are the source of truth; deleting the database only costs a re-scan.
/// Stored in Application Support, never in the vault.
public final class NoteIndex: Sendable {
    public let pool: DatabasePool
    public let vault: Vault

    // MARK: Rows

    public struct NoteRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable, Equatable {
        public static let databaseTableName = "note"
        public var id: Int64?
        public var relPath: String
        public var title: String
        public var stem: String       // lowercased filename without extension
        public var mtime: Double
        public var size: Int
        public var created: Double
        public var wordCount: Int

        public mutating func didInsert(_ inserted: InsertionSuccess) {
            id = inserted.rowID
        }
    }

    public struct SearchHit: Sendable, Identifiable, Equatable {
        public var id: Int64
        public let relPath: String
        public let title: String
        public let snippet: String
    }

    public struct Backlink: Sendable, Equatable {
        public let sourceRelPath: String
        public let sourceTitle: String
        public let rangeStart: Int
        public let rangeLength: Int
    }

    // MARK: Setup

    /// On-disk index for a vault (Application Support/Noiets/<vault-hash>/).
    public convenience init(vault: Vault) throws {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
        let digest = SHA256.hash(data: Data(vault.rootURL.path.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        let dir = support.appendingPathComponent("Noiets/\(hash)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try self.init(vault: vault, databaseURL: dir.appendingPathComponent("index.sqlite"))
    }

    public init(vault: Vault, databaseURL: URL) throws {
        self.vault = vault
        self.pool = try DatabasePool(path: databaseURL.path)
        try Self.migrator.migrate(pool)
    }

    /// Throwaway database in a temp directory (tests).
    public static func temporary(vault: Vault) throws -> NoteIndex {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noiets-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try NoteIndex(vault: vault, databaseURL: dir.appendingPathComponent("index.sqlite"))
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("relPath", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("stem", .text).notNull().indexed()
                t.column("mtime", .double).notNull()
                t.column("size", .integer).notNull()
                t.column("created", .double).notNull()
                t.column("wordCount", .integer).notNull()
            }
            // Regular (content-storing) FTS5: snippets work and rows delete
            // normally; the storage cost is fine for text vaults.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE note_fts
                USING fts5(title, body, tokenize='unicode61 remove_diacritics 2')
                """)
            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
            }
            try db.create(table: "note_tag") { t in
                t.column("noteId", .integer).notNull().references("note", onDelete: .cascade)
                t.column("tagId", .integer).notNull().references("tag", onDelete: .cascade)
                t.primaryKey(["noteId", "tagId"])
            }
            try db.create(table: "link") { t in
                t.column("sourceNoteId", .integer).notNull().references("note", onDelete: .cascade)
                t.column("targetTitle", .text).notNull().indexed()
                t.column("targetNoteId", .integer).indexed() // NULL = unresolved
                t.column("rangeStart", .integer).notNull()
                t.column("rangeLength", .integer).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            // Frontmatter properties, queryable by saved views.
            try db.create(table: "note_prop") { t in
                t.column("noteId", .integer).notNull().indexed()
                    .references("note", onDelete: .cascade)
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
            }
            try db.create(index: "note_prop_key_value", on: "note_prop",
                          columns: ["key", "value"])
            // The index is a rebuildable cache: wipe note rows so the
            // launch-time reconcile() re-extracts everything (populating
            // note_prop for pre-existing notes). Children first — migrations
            // run with foreign keys off, so ON DELETE CASCADE doesn't fire
            // and orphans would fail GRDB's end-of-migration FK check.
            try db.execute(sql: "DELETE FROM link")
            try db.execute(sql: "DELETE FROM note_tag")
            try db.execute(sql: "DELETE FROM note_fts")
            try db.execute(sql: "DELETE FROM tag")
            try db.execute(sql: "DELETE FROM note")
        }
        return migrator
    }

    // MARK: - Writes (called from the Reindexer)

    /// Inserts or updates one note plus its FTS row, tags, and outgoing links.
    public func upsert(
        relPath: String,
        extracted: ExtractedNote,
        mtime: Double,
        size: Int,
        created: Double
    ) throws {
        let stem = (relPath as NSString).lastPathComponent
        let stemNoExt = (stem as NSString).deletingPathExtension.lowercased()

        try pool.write { db in
            let existing = try NoteRow.filter(Column("relPath") == relPath).fetchOne(db)
            var row = existing ?? NoteRow(
                id: nil, relPath: relPath, title: extracted.title, stem: stemNoExt,
                mtime: mtime, size: size, created: created, wordCount: extracted.wordCount
            )
            row.title = extracted.title
            row.stem = stemNoExt
            row.mtime = mtime
            row.size = size
            row.wordCount = extracted.wordCount
            try row.save(db)
            guard let noteId = row.id else { return }

            // FTS row keyed to the note id.
            try db.execute(sql: "DELETE FROM note_fts WHERE rowid = ?", arguments: [noteId])
            try db.execute(
                sql: "INSERT INTO note_fts(rowid, title, body) VALUES(?, ?, ?)",
                arguments: [noteId, extracted.title, extracted.body]
            )

            // Tags
            try db.execute(sql: "DELETE FROM note_tag WHERE noteId = ?", arguments: [noteId])
            for tag in extracted.tags {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO tag(name) VALUES(?)", arguments: [tag]
                )
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO note_tag(noteId, tagId)
                    SELECT ?, id FROM tag WHERE name = ?
                    """,
                    arguments: [noteId, tag]
                )
            }

            // Frontmatter properties (one row per list element).
            try db.execute(sql: "DELETE FROM note_prop WHERE noteId = ?", arguments: [noteId])
            for (key, values) in extracted.props {
                for value in values {
                    try db.execute(
                        sql: "INSERT INTO note_prop(noteId, key, value) VALUES(?, ?, ?)",
                        arguments: [noteId, key, value.trimmingCharacters(in: .whitespaces)]
                    )
                }
            }

            // Outgoing links. Resolution is batch-level: callers run
            // resolveLinks() once per batch (per-upsert resolution is O(n²)
            // across a large reconcile).
            try db.execute(sql: "DELETE FROM link WHERE sourceNoteId = ?", arguments: [noteId])
            for link in extracted.links {
                try db.execute(
                    sql: """
                    INSERT INTO link(sourceNoteId, targetTitle, targetNoteId, rangeStart, rangeLength)
                    VALUES(?, ?, NULL, ?, ?)
                    """,
                    arguments: [noteId, link.targetTitle, link.rangeStart, link.rangeLength]
                )
            }
        }
    }

    public func deleteNote(relPath: String) throws {
        try pool.write { db in
            if let row = try NoteRow.filter(Column("relPath") == relPath).fetchOne(db),
               let id = row.id {
                try db.execute(sql: "DELETE FROM note_fts WHERE rowid = ?", arguments: [id])
                try row.delete(db) // cascades tags + outgoing links
                // Inbound links become unresolved.
                try db.execute(sql: "UPDATE link SET targetNoteId = NULL WHERE targetNoteId = ?",
                               arguments: [id])
            }
        }
    }

    /// Re-resolves every link edge: [[Target]] matches a note's filename stem
    /// first (Obsidian-style), then its title.
    public func resolveLinks() throws {
        try pool.write { db in
            // Two passes: SQLite allows correlated outer references in a
            // subquery's WHERE but not its ORDER BY. Stems win over titles.
            try db.execute(sql: """
                UPDATE link SET targetNoteId = (
                    SELECT n.id FROM note n
                    WHERE lower(n.stem) = lower(link.targetTitle) LIMIT 1
                )
                """)
            try db.execute(sql: """
                UPDATE link SET targetNoteId = (
                    SELECT n.id FROM note n
                    WHERE lower(n.title) = lower(link.targetTitle) LIMIT 1
                )
                WHERE targetNoteId IS NULL
                """)
        }
    }

    public func allNotes() throws -> [NoteRow] {
        try pool.read { db in
            try NoteRow.order(Column("relPath")).fetchAll(db)
        }
    }

    // MARK: - Queries

    public func searchNotes(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        // Sanitize into prefix-token FTS query: foo bar → "foo"* "bar"*
        let ftsQuery = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT n.id, n.relPath, n.title,
                       snippet(note_fts, 1, '', '', ' … ', 12) AS snippet
                FROM note_fts
                JOIN note n ON n.id = note_fts.rowid
                WHERE note_fts MATCH ?
                ORDER BY bm25(note_fts, 4.0, 1.0)
                LIMIT ?
                """,
                arguments: [ftsQuery, limit]
            )
            return rows.map {
                SearchHit(id: $0["id"], relPath: $0["relPath"], title: $0["title"],
                          snippet: $0["snippet"] ?? "")
            }
        }
    }

    /// Quick-open matcher: prefix beats contains, then recency.
    public func quickOpen(_ query: String, limit: Int = 30) throws -> [NoteRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return try pool.read { db in
            if q.isEmpty {
                return try NoteRow.order(Column("mtime").desc).limit(limit).fetchAll(db)
            }
            let escaped = q
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            return try NoteRow.fetchAll(
                db,
                sql: """
                SELECT * FROM note
                WHERE lower(title) LIKE ? ESCAPE '\\' OR lower(stem) LIKE ? ESCAPE '\\'
                ORDER BY
                    (lower(stem) LIKE ? ESCAPE '\\' OR lower(title) LIKE ? ESCAPE '\\') DESC,
                    mtime DESC
                LIMIT ?
                """,
                arguments: ["%\(escaped)%", "%\(escaped)%", "\(escaped)%", "\(escaped)%", limit]
            )
        }
    }

    public func recentNotes(limit: Int = 30) throws -> [NoteRow] {
        try pool.read { db in
            try NoteRow.order(Column("mtime").desc).limit(limit).fetchAll(db)
        }
    }

    public func backlinks(to relPath: String) throws -> [Backlink] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT src.relPath AS srcPath, src.title AS srcTitle,
                       l.rangeStart, l.rangeLength
                FROM link l
                JOIN note target ON target.id = l.targetNoteId
                JOIN note src ON src.id = l.sourceNoteId
                WHERE target.relPath = ?
                ORDER BY src.title
                """,
                arguments: [relPath]
            )
            return rows.map {
                Backlink(sourceRelPath: $0["srcPath"], sourceTitle: $0["srcTitle"],
                         rangeStart: $0["rangeStart"], rangeLength: $0["rangeLength"])
            }
        }
    }

    public func allTags() throws -> [(name: String, count: Int)] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.name AS name, COUNT(nt.noteId) AS cnt
                FROM tag t JOIN note_tag nt ON nt.tagId = t.id
                GROUP BY t.id ORDER BY cnt DESC, t.name
                """)
            return rows.map { ($0["name"], $0["cnt"]) }
        }
    }

    public func notes(withTag tag: String) throws -> [NoteRow] {
        try pool.read { db in
            try NoteRow.fetchAll(db, sql: """
                SELECT n.* FROM note n
                JOIN note_tag nt ON nt.noteId = n.id
                JOIN tag t ON t.id = nt.tagId
                WHERE t.name = ? ORDER BY n.mtime DESC
                """, arguments: [tag.lowercased()])
        }
    }

    /// Wiki-link resolution for navigation / create-on-missing (M5).
    public func note(matchingLinkTarget target: String) throws -> NoteRow? {
        try pool.read { db in
            try NoteRow.fetchOne(db, sql: """
                SELECT * FROM note
                WHERE lower(stem) = lower(?) OR lower(title) = lower(?)
                ORDER BY (lower(stem) = lower(?)) DESC LIMIT 1
                """, arguments: [target, target, target])
        }
    }
}
