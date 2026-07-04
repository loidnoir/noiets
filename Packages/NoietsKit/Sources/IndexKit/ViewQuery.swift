import Foundation
import GRDB

/// A parsed NoQL filter query — the model behind saved sidebar views.
///
/// One line of whitespace-separated tokens:
///
///     tag:project folder:Work draft status:done modified:<7d sort:-title limit:50
///
/// Bare words and `text:` terms full-text match; `title:` matches titles;
/// `tag:`/`folder:` filter by tag and rel-path prefix; `created:`/`modified:`
/// take `<`/`>` with `Nd` (days) or `YYYY-MM-DD`; any other `key:value` is a
/// frontmatter property (case-insensitive equals; `key:*` = has key).
/// Malformed tokens are ignored — live typing never errors.
public struct ViewQuery: Equatable, Sendable {
    public enum SortKey: String, Sendable {
        case modified, created, title, words
    }

    public enum DateFilter: Equatable, Sendable {
        case before(Double) // column < epoch
        case after(Double)  // column > epoch
    }

    public struct PropFilter: Equatable, Sendable {
        public let key: String    // lowercased
        public let value: String? // nil = has-key (`key:*`)

        public init(key: String, value: String?) {
            self.key = key
            self.value = value
        }
    }

    public var textTerms: [String] = []
    public var titleTerms: [String] = []
    public var tags: [String] = []
    public var folders: [String] = []
    public var created: [DateFilter] = []
    public var modified: [DateFilter] = []
    public var props: [PropFilter] = []
    public var sort: SortKey = .modified
    public var ascending = false
    public var limit = 200

    public init() {}

    public static func parse(_ text: String, now: Date = Date()) -> ViewQuery {
        var query = ViewQuery()

        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let colon = token.firstIndex(of: ":") else {
                query.textTerms.append(String(token))
                continue
            }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...])
            guard !key.isEmpty, !value.isEmpty else { continue }

            switch key {
            case "text":
                query.textTerms.append(value)
            case "title":
                query.titleTerms.append(value.lowercased())
            case "tag":
                query.tags.append(value.lowercased())
            case "folder":
                var folder = value.lowercased()
                while folder.hasSuffix("/") { folder.removeLast() }
                if !folder.isEmpty { query.folders.append(folder) }
            case "created":
                if let filter = Self.dateFilter(value, now: now) {
                    query.created.append(filter)
                }
            case "modified":
                if let filter = Self.dateFilter(value, now: now) {
                    query.modified.append(filter)
                }
            case "sort":
                var name = value.lowercased()
                var ascending = false
                if name.hasPrefix("-") {
                    ascending = true
                    name.removeFirst()
                }
                if let sort = SortKey(rawValue: name) {
                    query.sort = sort
                    query.ascending = ascending
                }
            case "limit":
                if let n = Int(value) {
                    query.limit = min(max(n, 1), 1000)
                }
            default:
                query.props.append(PropFilter(key: String(key),
                                              value: value == "*" ? nil : value.lowercased()))
            }
        }
        return query
    }

    /// `<7d` newer-than-7-days → after(now-7d); `>7d` older → before(now-7d);
    /// `<2026-01-01` → before(date); `>2026-01-01` → after(date).
    private static func dateFilter(_ value: String, now: Date) -> DateFilter? {
        guard let op = value.first, op == "<" || op == ">" else { return nil }
        let rest = String(value.dropFirst())

        if rest.hasSuffix("d"), let days = Int(rest.dropLast()), days >= 0 {
            let epoch = now.timeIntervalSince1970 - Double(days) * 86400
            return op == "<" ? .after(epoch) : .before(epoch)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: rest) else { return nil }
        let epoch = date.timeIntervalSince1970
        return op == "<" ? .before(epoch) : .after(epoch)
    }
}

// MARK: - Execution

extension NoteIndex {
    /// Runs a view query as one parameterized SELECT. Rows carry an FTS
    /// snippet when the query has text terms, else an empty snippet.
    /// Errors (e.g. pathological FTS syntax mid-typing) return [].
    public func notes(matching query: ViewQuery) throws -> [SearchHit] {
        var clauses: [String] = []
        var arguments: [DatabaseValueConvertible] = []

        func escapeLike(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
        }

        let hasText = !query.textTerms.isEmpty
        if hasText {
            let ftsQuery = query.textTerms
                .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
                .joined(separator: " ")
            clauses.append("note_fts MATCH ?")
            arguments.append(ftsQuery)
        }
        for tag in query.tags {
            clauses.append("""
                EXISTS (SELECT 1 FROM note_tag nt JOIN tag t ON t.id = nt.tagId
                        WHERE nt.noteId = n.id AND t.name = ?)
                """)
            arguments.append(tag)
        }
        for folder in query.folders {
            clauses.append("lower(n.relPath) LIKE ? ESCAPE '\\'")
            arguments.append(escapeLike(folder) + "/%")
        }
        for term in query.titleTerms {
            clauses.append("lower(n.title) LIKE ? ESCAPE '\\'")
            arguments.append("%" + escapeLike(term) + "%")
        }
        for (column, filters) in [("n.created", query.created), ("n.mtime", query.modified)] {
            for filter in filters {
                switch filter {
                case .before(let epoch):
                    clauses.append("\(column) < ?")
                    arguments.append(epoch)
                case .after(let epoch):
                    clauses.append("\(column) > ?")
                    arguments.append(epoch)
                }
            }
        }
        for prop in query.props {
            if let value = prop.value {
                clauses.append("""
                    EXISTS (SELECT 1 FROM note_prop p WHERE p.noteId = n.id
                            AND p.key = ? AND lower(p.value) = ?)
                    """)
                arguments.append(prop.key)
                arguments.append(value)
            } else {
                clauses.append("""
                    EXISTS (SELECT 1 FROM note_prop p WHERE p.noteId = n.id AND p.key = ?)
                    """)
                arguments.append(prop.key)
            }
        }

        let sortColumn: String
        switch query.sort {
        case .modified: sortColumn = "n.mtime"
        case .created: sortColumn = "n.created"
        case .title: sortColumn = "n.title COLLATE NOCASE"
        case .words: sortColumn = "n.wordCount"
        }
        let direction = query.ascending ? "ASC" : "DESC"

        let sql = """
        SELECT n.id, n.relPath, n.title,
               \(hasText ? "snippet(note_fts, 1, '', '', ' … ', 12)" : "''") AS snippet
        FROM note n
        \(hasText ? "JOIN note_fts ON note_fts.rowid = n.id" : "")
        WHERE \(clauses.isEmpty ? "1=1" : clauses.joined(separator: " AND "))
        ORDER BY \(sortColumn) \(direction), n.relPath ASC
        LIMIT ?
        """
        arguments.append(query.limit)

        do {
            return try pool.read { db in
                let rows = try Row.fetchAll(db, sql: sql,
                                            arguments: StatementArguments(arguments))
                return rows.map {
                    SearchHit(id: $0["id"], relPath: $0["relPath"], title: $0["title"],
                              snippet: $0["snippet"] ?? "")
                }
            }
        } catch {
            if ProcessInfo.processInfo.environment["NOIETS_DEBUG_VIEWS"] == "1" {
                fputs("VIEWQUERY error: \(error)\nSQL: \(sql)\n", stderr)
            }
            return [] // never crash live typing on odd FTS input
        }
    }
}
