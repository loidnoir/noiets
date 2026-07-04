import Foundation

/// Splits (but never rewrites) YAML frontmatter. The editor buffer always holds
/// the raw document, so preservation on save is byte-exact by construction —
/// this type only *locates* the frontmatter for the tokenizer and the indexer.
public struct Frontmatter: Equatable, Sendable {
    /// UTF-16 range of the whole frontmatter block including both `---` fences
    /// and the trailing newline of the closing fence (if present).
    public let range: NSRange
    /// The raw text inside the fences (excluding the fence lines themselves).
    public let content: String

    /// Detects frontmatter at the very start of the document: a first line of
    /// exactly `---` closed by a line of `---` or `...`.
    public static func parse(in text: String) -> Frontmatter? {
        let ns = text as NSString
        guard ns.length >= 4 else { return nil }
        // Must start with "---\n" exactly.
        guard ns.hasPrefix("---\n") else { return nil }

        var lineStart = 4 // past "---\n"
        while lineStart < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: lineStart, length: 0))
            let line = ns.substring(with: NSRange(location: start, length: contentsEnd - start))
            if line == "---" || line == "..." {
                let content = ns.substring(with: NSRange(location: 4, length: start - 4))
                return Frontmatter(range: NSRange(location: 0, length: end), content: content)
            }
            if end == lineStart { break } // safety: no progress
            lineStart = end
        }
        return nil
    }

    /// One parsed frontmatter entry. `values` holds one element per list item
    /// (`[a, b]` or `a, b`), or a single element for scalars; a bare `key:`
    /// yields `[""]` so has-key queries still match.
    public struct Property: Equatable, Sendable {
        public let key: String // trimmed, lowercased
        public let values: [String]

        public init(key: String, values: [String]) {
            self.key = key
            self.values = values
        }
    }

    /// Minimal hand-rolled `key: value` parser over the located block — no
    /// YAML dependency. Scalars, `[a, b]`, and comma lists only; indented
    /// (block-style) values and comments are skipped. Duplicate keys: last
    /// one wins.
    public static func parseProperties(_ content: String) -> [Property] {
        var byKey: [String: [String]] = [:]
        var order: [String] = []

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.first?.isWhitespace == true { continue } // block-style value line
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }

            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            let values: [String]
            if value.contains(",") {
                values = value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            } else {
                values = [unquote(value)]
            }

            if byKey[key] == nil { order.append(key) }
            byKey[key] = values // duplicate key: last wins
        }
        return order.compactMap { key in
            byKey[key].map { Property(key: key, values: $0) }
        }
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, first == s.last,
              first == "\"" || first == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }
}

private extension NSString {
    func hasPrefix(_ prefix: String) -> Bool {
        length >= (prefix as NSString).length && substring(to: (prefix as NSString).length) == prefix
    }
}
