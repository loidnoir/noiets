import Foundation
import GRDB
import Testing
@testable import IndexKit
import VaultStore

private func makeIndex() throws -> NoteIndex {
    try NoteIndex.temporary(vault: Vault(rootURL: URL(fileURLWithPath: "/tmp/fake-vault")))
}

private func put(
    _ index: NoteIndex, _ relPath: String, _ markdown: String,
    mtime: Double = 1000, created: Double = 900
) throws {
    let fallback = (relPath as NSString).lastPathComponent
        .replacingOccurrences(of: ".md", with: "")
    let extracted = NoteExtractor.extract(markdown: markdown, fallbackTitle: fallback)
    try index.upsert(relPath: relPath, extracted: extracted, mtime: mtime, size: 10,
                     created: created)
}

// MARK: - Parsing

@Suite struct ViewQueryParseTests {
    @Test func bareWordsAndTextMerge() {
        let q = ViewQuery.parse("alpha text:beta gamma")
        #expect(q.textTerms == ["alpha", "beta", "gamma"])
    }

    @Test func tagsFoldersTitles() {
        let q = ViewQuery.parse("tag:Work tag:deep folder:Uni/Notes/ title:Draft")
        #expect(q.tags == ["work", "deep"])
        #expect(q.folders == ["uni/notes"])
        #expect(q.titleTerms == ["draft"])
    }

    @Test func dateTokens() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let q = ViewQuery.parse("modified:<7d created:>2d", now: now)
        #expect(q.modified == [.after(1_000_000 - 7 * 86400)])
        #expect(q.created == [.before(1_000_000 - 2 * 86400)])

        let q2 = ViewQuery.parse("created:<2026-01-01 modified:>2026-01-01", now: now)
        guard case .before(let b) = q2.created.first, case .after(let a) = q2.modified.first
        else { Issue.record("missing date filters"); return }
        #expect(b == a)
        #expect(b > 1_700_000_000)
    }

    @Test func sortAndLimit() {
        let q = ViewQuery.parse("sort:words limit:25")
        #expect(q.sort == .words)
        #expect(!q.ascending)
        #expect(q.limit == 25)

        let q2 = ViewQuery.parse("sort:-title limit:99999")
        #expect(q2.sort == .title)
        #expect(q2.ascending)
        #expect(q2.limit == 1000) // clamped
    }

    @Test func unknownKeysBecomeProps() {
        let q = ViewQuery.parse("status:Done draft:*")
        #expect(q.props == [
            .init(key: "status", value: "done"),
            .init(key: "draft", value: nil),
        ])
    }

    @Test func malformedTokensIgnored() {
        let q = ViewQuery.parse("created:<abc sort:bogus limit:x : tag: folder:/")
        #expect(q == ViewQuery.parse("")) // all dropped → defaults
        #expect(q.sort == .modified)
        #expect(!q.ascending)
        #expect(q.limit == 200)
    }

    @Test func emptyQueryIsRecent() {
        let q = ViewQuery.parse("   ")
        #expect(q == ViewQuery())
        #expect(q.sort == .modified)
    }
}

// MARK: - Execution

@Suite struct ViewQueryExecutionTests {
    private static let now = 1_000_000.0

    private func seeded() throws -> NoteIndex {
        let index = try makeIndex()
        try put(index, "Work/Plan.md", """
        ---
        status: Done
        genre: [sci-fi, classic]
        ---
        # Plan
        Quarterly #work planning notes
        """, mtime: Self.now - 3600, created: 100) // an hour old
        try put(index, "Work/Deep/Focus.md", "# Focus\n#work #deep flow states",
                mtime: Self.now - 86400, created: 200) // a day old
        try put(index, "Journal.md", "# Journal\nDaily notes about planning",
                mtime: Self.now - 10 * 86400, created: 300) // ten days old
        return index
    }

    @Test func tagAndFolderFilters() throws {
        let index = try seeded()
        let both = try index.notes(matching: ViewQuery.parse("tag:work tag:deep"))
        #expect(both.map(\.relPath) == ["Work/Deep/Focus.md"])

        let folder = try index.notes(matching: ViewQuery.parse("folder:Work"))
        #expect(Set(folder.map(\.relPath)) == ["Work/Plan.md", "Work/Deep/Focus.md"])
    }

    @Test func textTermsCarrySnippets() throws {
        let index = try seeded()
        let hits = try index.notes(matching: ViewQuery.parse("planning"))
        #expect(Set(hits.map(\.relPath)) == ["Work/Plan.md", "Journal.md"])
        #expect(hits.allSatisfy { !$0.snippet.isEmpty })

        let plain = try index.notes(matching: ViewQuery.parse("tag:work"))
        #expect(plain.allSatisfy { $0.snippet.isEmpty })
    }

    @Test func propFilters() throws {
        let index = try seeded()
        let done = try index.notes(matching: ViewQuery.parse("status:DONE"))
        #expect(done.map(\.relPath) == ["Work/Plan.md"]) // case-insensitive

        let hasGenre = try index.notes(matching: ViewQuery.parse("genre:*"))
        #expect(hasGenre.map(\.relPath) == ["Work/Plan.md"])

        let listElement = try index.notes(matching: ViewQuery.parse("genre:classic"))
        #expect(listElement.map(\.relPath) == ["Work/Plan.md"])

        let none = try index.notes(matching: ViewQuery.parse("status:draft"))
        #expect(none.isEmpty)
    }

    @Test func dateWindows() throws {
        let index = try seeded()
        let now = Date(timeIntervalSince1970: Self.now)
        let newish = try index.notes(matching: ViewQuery.parse("modified:<2d", now: now))
        #expect(Set(newish.map(\.relPath)) == ["Work/Plan.md", "Work/Deep/Focus.md"])
        let old = try index.notes(matching: ViewQuery.parse("modified:>2d", now: now))
        #expect(old.map(\.relPath) == ["Journal.md"])
    }

    @Test func sortingAndLimit() throws {
        let index = try seeded()
        let byModified = try index.notes(matching: ViewQuery.parse(""))
        #expect(byModified.map(\.relPath) == ["Work/Plan.md", "Work/Deep/Focus.md", "Journal.md"])

        let byTitleAsc = try index.notes(matching: ViewQuery.parse("sort:-title"))
        #expect(byTitleAsc.map(\.title) == ["Focus", "Journal", "Plan"])

        let limited = try index.notes(matching: ViewQuery.parse("limit:1"))
        #expect(limited.count == 1)
    }

    @Test func injectionProbesAreData() throws {
        let index = try seeded()
        let a = try index.notes(matching: ViewQuery.parse("tag:x\"))OR((1=1--"))
        #expect(a.isEmpty)
        let b = try index.notes(matching: ViewQuery.parse("title:%"))
        #expect(b.isEmpty)
        let c = try index.notes(matching: ViewQuery.parse("status:');DROP--"))
        #expect(c.isEmpty)
        // Index still intact afterwards.
        #expect(try index.allNotes().count == 3)
    }

    /// Regression: v2 must migrate a POPULATED v1 database. Migrations run
    /// with foreign keys off, so the wipe has to delete child tables
    /// explicitly — orphans fail GRDB's end-of-migration FK check and the
    /// whole index refuses to open.
    @Test func v2MigratesPopulatedV1Database() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noiets-v1-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // Hand-build a v1 database with content in every table.
        let dbq = try DatabaseQueue(path: url.path)
        try dbq.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                CREATE TABLE note (id INTEGER PRIMARY KEY AUTOINCREMENT,
                    relPath TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
                    stem TEXT NOT NULL, mtime DOUBLE NOT NULL, size INTEGER NOT NULL,
                    created DOUBLE NOT NULL, wordCount INTEGER NOT NULL);
                CREATE INDEX note_stem ON note(stem);
                CREATE VIRTUAL TABLE note_fts
                    USING fts5(title, body, tokenize='unicode61 remove_diacritics 2');
                CREATE TABLE tag (id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE);
                CREATE TABLE note_tag (
                    noteId INTEGER NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    tagId INTEGER NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    PRIMARY KEY (noteId, tagId));
                CREATE TABLE link (
                    sourceNoteId INTEGER NOT NULL REFERENCES note(id) ON DELETE CASCADE,
                    targetTitle TEXT NOT NULL, targetNoteId INTEGER,
                    rangeStart INTEGER NOT NULL, rangeLength INTEGER NOT NULL);
                INSERT INTO grdb_migrations VALUES ('v1');
                INSERT INTO note(relPath, title, stem, mtime, size, created, wordCount)
                    VALUES ('a.md', 'A', 'a', 1, 1, 1, 1);
                INSERT INTO note_fts(rowid, title, body) VALUES (1, 'A', 'body');
                INSERT INTO tag(name) VALUES ('t');
                INSERT INTO note_tag(noteId, tagId) VALUES (1, 1);
                INSERT INTO link(sourceNoteId, targetTitle, targetNoteId, rangeStart, rangeLength)
                    VALUES (1, 'B', NULL, 0, 1);
                """)
        }

        // Opening through NoteIndex applies v2 — must not throw, and the
        // cache rows are wiped for the launch reconcile to rebuild.
        let vault = Vault(rootURL: URL(fileURLWithPath: "/tmp/fake-vault"))
        let index = try NoteIndex(vault: vault, databaseURL: url)
        #expect(try index.allNotes().isEmpty)
        #expect(try index.notes(matching: ViewQuery.parse("status:*")).isEmpty)
    }

    @Test func propRowsReplacedOnReupsert() throws {
        let index = try makeIndex()
        try put(index, "a.md", "---\nstatus: draft\n---\nbody")
        try put(index, "a.md", "---\nstatus: final\n---\nbody")
        #expect(try index.notes(matching: ViewQuery.parse("status:draft")).isEmpty)
        #expect(try index.notes(matching: ViewQuery.parse("status:final")).count == 1)
        try index.deleteNote(relPath: "a.md")
        #expect(try index.notes(matching: ViewQuery.parse("status:final")).isEmpty)
    }
}
