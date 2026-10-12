import Foundation

extension HTMLExport {
    public struct ImageReference: Equatable, Sendable {
        public let range: NSRange
        public let path: String
        public let alt: String
    }

    public struct ImageSource: Sendable {
        public let url: String
        public let width: Double?
        public let height: Double?

        public init(url: String, width: Double? = nil, height: Double? = nil) {
            self.url = url
            self.width = width
            self.height = height
        }
    }

    /// The same inline tokens used for export; code, math, and frontmatter
    /// cannot accidentally trigger file reads or remote image downloads.
    public static func images(in markdown: String) -> [ImageReference] {
        let text = markdown as NSString
        return BlockScan.scan(text).lines.flatMap { line -> [ImageReference] in
            switch line.kind {
            case .paragraph, .heading, .listItem, .blockquote, .tableRow:
                return imageReferences(text, range: line.contentRange)
            default: return []
            }
        }
    }

    static func imageReferences(_ text: NSString, range: NSRange) -> [ImageReference] {
        let tokens = InlineScanner.tokens(text, in: range)
        var images: [ImageReference] = []
        for token in tokens {
            if token.kind == .linkBracket, text.substring(with: token.range) == "![" {
                let start = NSMaxRange(token.range)
                let alt = tokens.first { $0.kind == .linkText && $0.range.location == start }?.range
                    ?? NSRange(location: start, length: 0)
                let urlStart = NSMaxRange(alt) + 2 // ](
                guard let url = tokens.first(where: { $0.kind == .linkURL && $0.range.location == urlStart }) else { continue }
                images.append(ImageReference(range: NSRange(location: token.range.location,
                                                            length: NSMaxRange(url.range) + 1 - token.range.location),
                                             path: text.substring(with: url.range), alt: text.substring(with: alt)))
            } else if token.kind == .wikiLinkMarker, text.substring(with: token.range) == "[[",
                      token.range.location > range.location,
                      text.character(at: token.range.location - 1) == 33 {
                let bang = token.range.location - 1
                var backslashes = 0
                var i = bang - 1
                while i >= range.location, text.character(at: i) == 92 { backslashes += 1; i -= 1 }
                guard backslashes % 2 == 0,
                      let target = tokens.first(where: { $0.kind == .wikiLinkTarget && $0.range.location == NSMaxRange(token.range) }),
                      let close = tokens.first(where: { $0.kind == .wikiLinkMarker && $0.range.location >= NSMaxRange(target.range)
                          && text.substring(with: $0.range) == "]]" }) else { continue }
                let path = text.substring(with: target.range).trimmingCharacters(in: .whitespaces)
                let ext = (path as NSString).pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "svg", "pdf"].contains(ext) else { continue }
                let alias = tokens.first { $0.kind == .wikiLinkAlias && $0.range.location < close.range.location
                    && $0.range.location > NSMaxRange(target.range) }
                images.append(ImageReference(range: NSRange(location: bang, length: NSMaxRange(close.range) - bang),
                                             path: path, alt: alias.map { text.substring(with: $0.range) } ?? path))
            }
        }
        return images
    }
}
