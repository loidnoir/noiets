import Foundation
import MarkdownKit
import SharedModel

/// Pulls index-relevant data (title, tags, wiki-link edges, word count) out of
/// a note's raw markdown using the same tokenizer the editor uses.
public struct ExtractedNote: Sendable {
    public struct LinkEdge: Sendable, Equatable {
        public let targetTitle: String // normalized: no #heading, no alias
        public let rangeStart: Int
        public let rangeLength: Int
    }

    public let title: String
    public let tags: Set<String>
    public let links: [LinkEdge]
    public let wordCount: Int
    public let body: String
}

public enum NoteExtractor {
    public static func extract(markdown: String, fallbackTitle: String) -> ExtractedNote {
        let ns = markdown as NSString
        let scan = BlockScan.scan(ns)

        var title: String?
        var tags = Set<String>()
        var links: [ExtractedNote.LinkEdge] = []

        for line in scan.lines {
            for token in MarkdownScan.lineTokens(ns, line: line) {
                switch token.kind {
                case .headingText(let level) where level == 1 && title == nil:
                    title = ns.substring(with: token.range).trimmingCharacters(in: .whitespaces)
                case .tagName:
                    tags.insert(ns.substring(with: token.range).lowercased())
                case .wikiLinkTarget:
                    var target = ns.substring(with: token.range)
                        .trimmingCharacters(in: .whitespaces)
                    if let hash = target.firstIndex(of: "#") { // [[Note#Heading]]
                        target = String(target[target.startIndex..<hash])
                            .trimmingCharacters(in: .whitespaces)
                    }
                    if !target.isEmpty {
                        links.append(.init(
                            targetTitle: target,
                            rangeStart: token.range.location,
                            rangeLength: token.range.length
                        ))
                    }
                default:
                    break
                }
            }
        }

        // Frontmatter tags: handles `tags: [a, b]` and `tags: a, b`.
        if let fm = Frontmatter.parse(in: markdown) {
            for rawLine in fm.content.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.lowercased().hasPrefix("tags:") else { continue }
                var value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                for item in value.split(whereSeparator: { $0 == "," || $0 == " " }) {
                    let tag = item.trimmingCharacters(in: CharacterSet(charactersIn: "\"' #"))
                    if !tag.isEmpty { tags.insert(tag.lowercased()) }
                }
            }
        }

        let words = markdown.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

        return ExtractedNote(
            title: title?.isEmpty == false ? title! : fallbackTitle,
            tags: tags,
            links: links,
            wordCount: words,
            body: markdown
        )
    }
}
