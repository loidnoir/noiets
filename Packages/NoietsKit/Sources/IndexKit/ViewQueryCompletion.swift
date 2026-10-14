import Foundation
import GRDB

/// Syntax suggestions for the token under the caret; accepting one never
/// replaces the rest of the query or silently changes the grammar.
public enum ViewQueryCompletion {
    public struct Suggestion: Equatable, Sendable {
        public let text: String
        public let range: NSRange
    }

    public static func suggestions(in text: String, caret: Int, tags: [String] = [],
                                   folders: [String] = [], properties: [String: [String]] = [:]) -> [Suggestion] {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return [] }
        func isSpace(_ index: Int) -> Bool {
            UnicodeScalar(ns.character(at: index)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
        }
        var start = caret
        var end = caret
        while start > 0, !isSpace(start - 1) { start -= 1 }
        while end < ns.length, !isSpace(end) { end += 1 }
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start)).lowercased()
        guard !prefix.isEmpty else { return [] }
        let keys = ["widget", "layout", "sort", "tag", "folder", "modified", "created", "limit", "title", "text"]
        var candidates: [String]
        if let colon = prefix.firstIndex(of: ":") {
            let key = String(prefix[..<colon])
            let values: [String]
            switch key {
            case "widget":
                let head = "widget:heatmap?tags="
                if prefix.hasPrefix(head) {
                    let entered = String(prefix.dropFirst(head.count))
                    let parts = entered.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    let stem = parts.dropLast().joined(separator: ",")
                    let used = Set(parts.dropLast())
                    candidates = tags.filter { !used.contains($0.lowercased()) }.map {
                        head + (stem.isEmpty ? "" : stem + ",") + $0
                    }
                    var seen = Set<String>()
                    return candidates.filter {
                        !$0.contains(where: \.isWhitespace) && $0.lowercased().hasPrefix(prefix) && $0.lowercased() != prefix && seen.insert($0).inserted
                    }.prefix(8).map { Suggestion(text: $0, range: NSRange(location: start, length: end - start)) }
                }
                values = ["heatmap", "heatmap?tags", "heatmap?tags="]
            case "layout": values = ["week", "month", "year", "tag", "folder"]
            case "sort": values = ["modified", "created", "title", "words", "-modified", "-created", "-title", "-words"]
            case "tag": values = tags
            case "folder": values = folders
            case "modified", "created": values = ["<7d", "<30d", ">7d", ">30d", ">\(Calendar.current.component(.year, from: Date()))-01-01"]
            case "limit": values = ["25", "50", "100", "200", "500", "1000"]
            default: values = properties[key].map { ["*"] + $0 } ?? []
            }
            candidates = values.filter { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }.map { "\(key):\($0)" }
        } else {
            candidates = (keys + properties.keys.sorted().filter { !keys.contains($0) && !$0.contains(where: \.isWhitespace) }).map { "\($0):" }
        }
        var seen = Set<String>()
        return candidates.filter { $0.lowercased().hasPrefix(prefix) && $0.lowercased() != prefix && seen.insert($0).inserted }
            .prefix(8).map { Suggestion(text: $0, range: NSRange(location: start, length: end - start)) }
    }
}

extension NoteIndex {
    public func queryCompletionProperties() throws -> [String: [String]] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT key, value FROM note_prop ORDER BY key, value")
            var result: [String: [String]] = [:]
            for row in rows {
                let key: String = row["key"]
                let value: String = row["value"]
                result[key.lowercased(), default: []].append(value)
            }
            return result
        }
    }
}
