import Foundation
import SharedModel

/// Minimal, dependency-free HTML export driven by the same scanner the editor
/// uses — so what you see is what exports. Math is left as TeX source in
/// `.math` spans; code blocks keep their language as a class.
public enum HTMLExport {
    /// Optional resource mapping makes print exports self-contained. A missing
    /// mapped image gets a visible placeholder rather than being dropped.
    public static func html(from markdown: String, title: String,
                            additionalCSS: String = "", preserveBlankLines: Bool = false,
                            imageSource: ((String) -> ImageSource?)? = nil) -> String {
        let ns = markdown as NSString
        let scan = BlockScan.scan(ns)
        var body: [String] = []

        enum Container {
            case none, ul, ol, blockquote, pre(String?), mermaid, table
        }
        var container = Container.none
        var hasMermaid = false
        var quoteParagraphOpen = false
        func inline(_ range: NSRange) -> String { inlineHTML(ns, range: range, imageSource: imageSource) }

        func close() {
            switch container {
            case .none: break
            case .ul: body.append("</ul>")
            case .ol: body.append("</ol>")
            case .blockquote:
                if quoteParagraphOpen { body.append("</p>") }
                quoteParagraphOpen = false
                body.append("</blockquote>")
            case .pre: body.append("</code></pre>")
            case .mermaid: body.append("</div>")
            case .table: body.append("</tbody></table>")
            }
            container = .none
        }

        func ensure(_ target: Container) {
            switch (container, target) {
            case (.ul, .ul), (.ol, .ol), (.blockquote, .blockquote), (.pre, .pre),
                 (.mermaid, .mermaid), (.table, .table):
                return
            default:
                close()
                switch target {
                case .none: break
                case .ul: body.append("<ul>")
                case .ol: body.append("<ol>")
                case .blockquote: body.append("<blockquote>")
                case .pre(let lang):
                    let cls = lang.map { " class=\"language-\(escape($0))\"" } ?? ""
                    body.append("<pre><code\(cls)>")
                case .mermaid: body.append("<div class=\"mermaid\">")
                case .table: body.append("<table><tbody>")
                }
                container = target
            }
        }

        for (index, line) in scan.lines.enumerated() {
            switch line.kind {
            case .blank:
                close()
                if preserveBlankLines { body.append("<div class=\"blank-line\" aria-hidden=\"true\"></div>") }
            case .frontmatterDelimiter, .frontmatterContent:
                continue
            case .heading(let level, _, let textRange):
                close()
                body.append("<h\(level)>\(inline(textRange))</h\(level)>")
            case .horizontalRule:
                close()
                body.append("<hr>")
            case .fenceDelimiter(let language):
                switch container {
                case .pre, .mermaid:
                    close()
                default:
                    if language?.lowercased() == "mermaid" {
                        hasMermaid = true
                        ensure(.mermaid)
                    } else {
                        ensure(.pre(language))
                    }
                }
            case .code:
                switch container {
                case .pre, .mermaid: break
                default: ensure(.pre(nil))
                }
                body.append(escape(ns.substring(with: line.contentRange)))
            case .listItem(_, let ordered, let task, let contentStart):
                ensure(ordered ? .ol : .ul)
                let end = line.contentRange.location + line.contentRange.length
                let content = contentStart < end
                    ? inline(NSRange(location: contentStart, length: end - contentStart))
                    : ""
                if let task {
                    let checked = task.checked ? " checked" : ""
                    body.append("<li class=\"task\(task.checked ? " completed" : "")\"><input type=\"checkbox\" disabled\(checked)> \(content)</li>")
                } else {
                    body.append("<li>\(content)</li>")
                }
            case .blockquote(_, let contentStart):
                ensure(.blockquote)
                let end = line.contentRange.location + line.contentRange.length
                let range = NSRange(location: contentStart, length: end - contentStart)
                if ns.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty {
                    if quoteParagraphOpen { body.append("</p>") }
                    quoteParagraphOpen = false
                    if preserveBlankLines { body.append("<div class=\"blank-line\" aria-hidden=\"true\"></div>") }
                } else {
                    if !quoteParagraphOpen { body.append("<p>") }
                    quoteParagraphOpen = true
                    body.append(inline(range))
                }
            case .tableRow:
                let isHeader = index + 1 < scan.lines.count && {
                    if case .tableDelimiterRow = scan.lines[index + 1].kind { return true }
                    return false
                }()
                ensure(.table)
                let cells = ns.substring(with: line.contentRange)
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .drop(while: \.isEmpty)
                    .reversed().drop(while: \.isEmpty).reversed()
                let tag = isHeader ? "th" : "td"
                let row = cells.map { "<\(tag)>\(escapeInlineCell(String($0), imageSource: imageSource))</\(tag)>" }.joined()
                body.append("<tr>\(row)</tr>")
            case .tableDelimiterRow, .mathDelimiter:
                continue
            case .mathBlockContent:
                close()
                if line.contentRange.length > 0 {
                    body.append("<p class=\"math\">\(escape(ns.substring(with: line.contentRange)))</p>")
                }
            case .paragraph:
                close()
                body.append("<p>\(inline(line.contentRange))</p>")
            }
        }
        close()

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>
        body { font: 16px/1.6 -apple-system, system-ui, sans-serif; max-width: 720px;
               margin: 3rem auto; padding: 0 1.5rem; color: #2b2b2b; }
        code { font: 0.9em ui-monospace, monospace; background: #f2f2f0; padding: 1px 5px;
               border-radius: 4px; }
        pre { background: #f6f6f4; padding: 14px 16px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 1em; color: #555; }
        table { border-collapse: collapse; }
        th, td { border-bottom: 1px solid #ddd; text-align: left; padding: 6px 14px 6px 0; }
        th { border-bottom-width: 2px; }
        mark { background: #ffef9e; }
        a { color: #5faaec; text-decoration: none; }
        hr { border: none; border-top: 1px solid #ddd; margin: 2em 0; }
        .math { color: #8a4a55; font-style: italic; }
        .mermaid svg { max-width: 100%; }
        img { max-width: 100%; }
        @media (prefers-color-scheme: dark) {
          body { background: #1d1d1f; color: #dcdcda; }
          code { background: #2c2c2e; }
          pre { background: #282829; }
          th, td { border-color: #444; }
          blockquote { border-color: #555; color: #aaa; }
          mark { background: #6b5d1f; color: #eee; }
        }
        /* PDF export prints this same document: keep the code/pre/mark
           backgrounds (print media strips them by default) and let the
           print margins own the page inset instead of the 3rem body margin. */
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        @media print {
          body { margin: 0 auto; padding: 0; }
          pre { overflow-x: hidden; white-space: pre-wrap; }
        }
        \(additionalCSS)
        </style>
        </head>
        <body>
        \(body.joined(separator: "\n"))\(hasMermaid ? Self.mermaidScript : "")
        </body>
        </html>
        """
    }

    /// The exact tag mermaid exports embed; PDF export swaps it for the
    /// vendored source so printing never touches the network.
    public static let mermaidScriptTag =
        "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js\"></script>"

    /// Only exports containing a ```mermaid fence pull in the renderer —
    /// from the CDN, so the exported file stays a single small document.
    /// Offline, the diagram degrades to its readable source text.
    private static let mermaidScript = """

    \(mermaidScriptTag)
    <script>mermaid.initialize({ startOnLoad: true, theme: \
    matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'neutral' });</script>
    """

    // MARK: Inline rendering

    private static func inlineHTML(_ text: NSString, range: NSRange,
                                   imageSource: ((String) -> ImageSource?)? = nil) -> String {
        let tokens = InlineScanner.tokens(text, in: range)
        let images = imageReferences(text, range: range)
        var events: [(location: Int, priority: Int, text: String)] = []

        func wrap(_ contentRange: NSRange, _ open: String, _ close: String) {
            events.append((contentRange.location, 0, open))
            events.append((contentRange.location + contentRange.length, 1, close))
        }

        var skip: [NSRange] = [] // marker/url runs excluded from text output
        for image in images {
            let asset: ImageSource?
            if let imageSource { asset = imageSource(image.path) }
            else { asset = ImageSource(url: image.path) }
            let markup: String
            if let asset {
                var size = ""
                if let width = asset.width, width.isFinite, width > 0 { size += " width=\"\(width)\"" }
                if let height = asset.height, height.isFinite, height > 0 { size += " height=\"\(height)\"" }
                markup = "<img src=\"\(escape(asset.url))\" alt=\"\(escape(image.alt))\"\(size)>"
            } else {
                markup = "<span class=\"missing-image\">Image unavailable: \(escape(image.path))</span>"
            }
            events.append((image.range.location, 2, markup))
            skip.append(image.range)
        }
        var index = 0
        for token in tokens {
            defer { index += 1 }
            if images.contains(where: { NSIntersectionRange($0.range, token.range) == token.range }) { continue }
            switch token.kind {
            case .emphasisMarker, .inlineCodeMarker, .linkBracket, .wikiLinkMarker,
                 .tagMarker, .mathMarker:
                skip.append(token.range)
            case .bold: wrap(token.range, "<strong>", "</strong>")
            case .italic: wrap(token.range, "<em>", "</em>")
            case .boldItalic: wrap(token.range, "<strong><em>", "</em></strong>")
            case .strikethrough: wrap(token.range, "<del>", "</del>")
            case .highlight: wrap(token.range, "<mark>", "</mark>")
            case .inlineCode: wrap(token.range, "<code>", "</code>")
            case .mathContent: wrap(token.range, "<span class=\"math\">", "</span>")
            case .linkText:
                if index + 2 < tokens.count, case .linkURL = tokens[index + 2].kind {
                    let url = escape(text.substring(with: tokens[index + 2].range))
                    wrap(token.range, "<a href=\"\(url)\">", "</a>")
                }
            case .linkURL:
                if index == 0 || !(tokens[index - 1].kind == .linkBracket) {
                    let url = escape(text.substring(with: token.range))
                    wrap(token.range, "<a href=\"\(url)\">", "</a>")
                } else {
                    skip.append(token.range)
                }
            case .wikiLinkTarget:
                if index + 2 < tokens.count, tokens[index + 2].kind == .wikiLinkAlias {
                    skip.append(token.range)
                } else {
                    wrap(token.range, "<a href=\"\(escape(text.substring(with: token.range))).html\">", "</a>")
                }
            case .wikiLinkAlias:
                wrap(token.range, "<a>", "</a>")
            case .tagName:
                wrap(token.range, "<a class=\"tag\">#", "</a>")
            default:
                break
            }
        }

        var out = ""
        var i = range.location
        let end = range.location + range.length
        events.sort { $0.location != $1.location ? $0.location < $1.location : $0.priority > $1.priority }
        var eventIndex = 0
        while i < end {
            while eventIndex < events.count, events[eventIndex].location <= i {
                out += events[eventIndex].text
                eventIndex += 1
            }
            if let hidden = skip.first(where: { i >= $0.location && i < $0.location + $0.length }) {
                i = hidden.location + hidden.length
                continue
            }
            let composed = text.rangeOfComposedCharacterSequence(at: i)
            let visible = NSIntersectionRange(composed, NSRange(location: i, length: end - i))
            out += escape(text.substring(with: visible))
            i = NSMaxRange(visible)
        }
        while eventIndex < events.count, events[eventIndex].location <= end {
            out += events[eventIndex].text
            eventIndex += 1
        }
        return out
    }

    private static func escapeInlineCell(_ s: String, imageSource: ((String) -> ImageSource?)?) -> String {
        inlineHTML(s as NSString, range: NSRange(location: 0, length: (s as NSString).length), imageSource: imageSource)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
