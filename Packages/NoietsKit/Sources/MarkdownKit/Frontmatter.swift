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
}

private extension NSString {
    func hasPrefix(_ prefix: String) -> Bool {
        length >= (prefix as NSString).length && substring(to: (prefix as NSString).length) == prefix
    }
}
