import Foundation
import SharedModel

/// Minimal, dependency-free HTML export driven by the same scanner the editor
/// uses — so what you see is what exports. Math is left as TeX source in
/// `.math` spans; code blocks keep their language as a class.
public enum HTMLExport {
    public static func html(from markdown: String, title: String) -> String {
        let ns = markdown as NSString
        let scan = BlockScan.scan(ns)
        var body: [String] = []

        enum Container {
            case none, ul, ol, blockquote, pre(String?), table
        }
        var container = Container.none

        func close() {
            switch container {
            case .none: break
            case .ul: body.append("</ul>")
            case .ol: body.append("</ol>")
            case .blockquote: body.append("</blockquote>")
            case .pre: body.append("</code></pre>")
            case .table: body.append("</tbody></table>")
            }
            container = .none
        }

        func ensure(_ target: Container) {
            switch (container, target) {
            case (.ul, .ul), (.ol, .ol), (.blockquote, .blockquote), (.pre, .pre), (.table, .table):
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
                case .table: body.append("<table><tbody>")
                }
                container = target
            }
        }

        for (index, line) in scan.lines.enumerated() {
            switch line.kind {
            case .blank:
                close()
            case .frontmatterDelimiter, .frontmatterContent:
                continue
            case .heading(let level, _, let textRange):
                close()
                body.append("<h\(level)>\(inlineHTML(ns, range: textRange))</h\(level)>")
            case .horizontalRule:
                close()
                body.append("<hr>")
            case .fenceDelimiter(let language):
                if case .pre = container {
                    close()
                } else {
                    ensure(.pre(language))
                }
            case .code:
                if case .pre = container {} else { ensure(.pre(nil)) }
                body.append(escape(ns.substring(with: line.contentRange)))
            case .listItem(_, let ordered, let task, let contentStart):
                ensure(ordered ? .ol : .ul)
                let end = line.contentRange.location + line.contentRange.length
                let content = contentStart < end
                    ? inlineHTML(ns, range: NSRange(location: contentStart, length: end - contentStart))
                    : ""
                if let task {
                    let checked = task.checked ? " checked" : ""
                    body.append("<li><input type=\"checkbox\" disabled\(checked)> \(content)</li>")
                } else {
                    body.append("<li>\(content)</li>")
                }
            case .blockquote(_, let contentStart):
                ensure(.blockquote)
                let end = line.contentRange.location + line.contentRange.length
                if contentStart < end {
                    body.append("<p>\(inlineHTML(ns, range: NSRange(location: contentStart, length: end - contentStart)))</p>")
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
                let row = cells.map { "<\(tag)>\(escapeInlineCell(String($0)))</\(tag)>" }.joined()
                body.append("<tr>\(row)</tr>")
            case .tableDelimiterRow:
                continue
            case .paragraph:
                close()
                body.append("<p>\(inlineHTML(ns, range: line.contentRange))</p>")
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
        a { color: #2069e0; text-decoration: none; }
        hr { border: none; border-top: 1px solid #ddd; margin: 2em 0; }
        .math { color: #8a4a55; font-style: italic; }
        img { max-width: 100%; }
        @media (prefers-color-scheme: dark) {
          body { background: #1d1d1f; color: #dcdcda; }
          code { background: #2c2c2e; }
          pre { background: #282829; }
          th, td { border-color: #444; }
          blockquote { border-color: #555; color: #aaa; }
          mark { background: #6b5d1f; color: #eee; }
        }
        </style>
        </head>
        <body>
        \(body.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    // MARK: Inline rendering

    private static func inlineHTML(_ text: NSString, range: NSRange) -> String {
        let tokens = InlineScanner.tokens(text, in: range)
        var events: [(location: Int, priority: Int, text: String)] = []

        func wrap(_ contentRange: NSRange, _ open: String, _ close: String) {
            events.append((contentRange.location, 0, open))
            events.append((contentRange.location + contentRange.length, 1, close))
        }

        var skip: [NSRange] = [] // marker/url runs excluded from text output
        var index = 0
        for token in tokens {
            defer { index += 1 }
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
            while eventIndex < events.count, events[eventIndex].location == i {
                out += events[eventIndex].text
                eventIndex += 1
            }
            if let hidden = skip.first(where: { i >= $0.location && i < $0.location + $0.length }) {
                i = hidden.location + hidden.length
                continue
            }
            out += escape(text.substring(with: NSRange(location: i, length: 1)))
            i += 1
        }
        while eventIndex < events.count, events[eventIndex].location <= end {
            out += events[eventIndex].text
            eventIndex += 1
        }
        return out
    }

    private static func escapeInlineCell(_ s: String) -> String {
        inlineHTML(s as NSString, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
