import AppKit
import MarkdownKit
import RenderKit
import SharedModel

/// NSTextLayoutManagerDelegate: swaps in custom layout fragments for block
/// content on inactive lines — inline images, display math, table grids — and
/// full-width background bands for code lines. The backing store still holds
/// raw markdown; only rendering changes, so indices/caret/vim stay truthful.
@MainActor
public final class LivePreviewLayoutController: NSObject {
    let theme: EditorTheme
    public let imageProvider = ImageProvider()
    private weak var highlighter: IncrementalHighlighter?
    private weak var contentStorage: NSTextContentStorage?

    init(theme: EditorTheme, highlighter: IncrementalHighlighter, contentStorage: NSTextContentStorage?) {
        self.theme = theme
        self.highlighter = highlighter
        self.contentStorage = contentStorage
        super.init()
    }

    // MARK: Classification

    private enum LineRole {
        case plain
        case code(roundTop: Bool, roundBottom: Bool)
        case image(path: String)
        case math(latex: String)
        case overlays(spans: [OverlayLineFragment.Span])
        case tableRow(cells: [String], isHeader: Bool, columns: [CGFloat])
        case tableDelimiter
        case quote
        case rule
    }

    private func role(forLineAt charIndex: Int, text: NSString) -> LineRole {
        guard let scan = highlighter?.currentScan, !scan.lines.isEmpty,
              charIndex <= text.length else { return .plain }
        let lineIndex = scan.lineIndex(containing: min(charIndex, max(0, text.length - 1)))
        guard lineIndex < scan.lines.count else { return .plain }
        let line = scan.lines[lineIndex]

        let active = highlighter.map { h in
            !h.alwaysPreview && (
                NSIntersectionRange(line.range, h.activeParagraphRange).length > 0
                    || (h.activeParagraphRange.length == 0
                        && h.activeParagraphRange.location >= line.range.location
                        && h.activeParagraphRange.location <= line.range.location + line.range.length)
                    || !h.livePreviewEnabled
            )
        } ?? true

        switch line.kind {
        case .code, .fenceDelimiter:
            // Band always (even while editing); the block's outer lines
            // round their corners.
            func isCode(_ i: Int) -> Bool {
                switch scan.lines[i].kind {
                case .code, .fenceDelimiter: return true
                default: return false
                }
            }
            return .code(roundTop: lineIndex == 0 || !isCode(lineIndex - 1),
                         roundBottom: lineIndex == scan.lines.count - 1 || !isCode(lineIndex + 1))
        case .blockquote:
            return .quote
        case .horizontalRule where !active:
            return .rule
        case .mathDelimiter where !active:
            return .tableDelimiter // collapse the $$ fence lines
        case .mathBlockContent where !active:
            // The first content line renders the whole block; the rest collapse.
            var first = lineIndex
            while first > 0, case .mathBlockContent = scan.lines[first - 1].kind {
                first -= 1
            }
            if lineIndex > first {
                return .tableDelimiter
            }
            var last = lineIndex
            while last < scan.lines.count - 1,
                  case .mathBlockContent = scan.lines[last + 1].kind {
                last += 1
            }
            let latex = (first...last)
                .map { text.substring(with: scan.lines[$0].contentRange) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return latex.isEmpty ? .plain : .math(latex: latex)
        case .tableDelimiterRow where !active:
            return .tableDelimiter
        case .tableRow where !active:
            let cells = Self.cells(of: text.substring(with: line.contentRange))
            let (columns, headerIndex) = tableGeometry(for: lineIndex, scan: scan, text: text)
            return .tableRow(cells: cells, isHeader: lineIndex == headerIndex, columns: columns)
        case .listItem(let markerRange, let ordered, let task, _) where !active:
            let tokens = MarkdownScan.lineTokens(text, line: line)
            var spans = inlineMathSpans(tokens: tokens, text: text, base: line.range.location)
            if let task {
                spans.insert(.init(relativeLocation: task.range.location - line.range.location,
                                   kind: .checkbox(checked: task.checked)), at: 0)
            } else if !ordered {
                spans.insert(.init(relativeLocation: markerRange.location - line.range.location,
                                   kind: .bullet), at: 0)
            }
            return spans.isEmpty ? .plain : .overlays(spans: spans)
        case .paragraph where !active:
            // Obsidian-style image embed on its own line: ![[image.png]]
            let trimmedLine = text.substring(with: line.contentRange)
                .trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("![["), trimmedLine.hasSuffix("]]") {
                let inner = String(trimmedLine.dropFirst(3).dropLast(2))
                    .trimmingCharacters(in: .whitespaces)
                let ext = (inner as NSString).pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains(ext) {
                    return .image(path: inner)
                }
            }
            let tokens = MarkdownScan.lineTokens(text, line: line)
            // Image-only line: ![alt](path) and nothing else.
            let significant = tokens.filter { $0.kind != .linkText }
            if significant.count == 4,
               case .linkBracket = significant[0].kind,
               tokens.contains(where: { if case .linkURL = $0.kind { return true }; return false }),
               text.substring(with: significant[0].range).hasPrefix("!") {
                let content = text.substring(with: line.contentRange).trimmingCharacters(in: .whitespaces)
                if content.hasPrefix("!"), content.hasSuffix(")"),
                   let url = tokens.first(where: { if case .linkURL = $0.kind { return true }; return false }) {
                    return .image(path: text.substring(with: url.range))
                }
            }
            // Display-math-only line: $$…$$
            if tokens.count == 3,
               case .mathContent(display: true) = tokens[1].kind {
                let content = text.substring(with: line.contentRange).trimmingCharacters(in: .whitespaces)
                if content.hasPrefix("$$"), content.hasSuffix("$$") {
                    return .math(latex: text.substring(with: tokens[1].range))
                }
            }
            // Math mixed into the text: typeset inline over the collapsed spans.
            let spans = inlineMathSpans(tokens: tokens, text: text, base: line.range.location)
            if !spans.isEmpty {
                return .overlays(spans: spans)
            }
            return .plain
        default:
            return .plain
        }
    }

    /// Marker-content-marker runs of a line — inline math and inline-code
    /// chips — as fragment-relative spans. Mirrors the highlighter's collapse
    /// rule: a span appears here iff its width was reserved there.
    private func inlineMathSpans(
        tokens: [Token], text: NSString, base: Int
    ) -> [OverlayLineFragment.Span] {
        var spans: [OverlayLineFragment.Span] = []
        for (i, token) in tokens.enumerated() {
            switch token.kind {
            case .mathContent(let display):
                guard i > 0, i + 1 < tokens.count,
                      tokens[i - 1].kind == .mathMarker,
                      tokens[i + 1].kind == .mathMarker,
                      let image = InlineMath.image(latex: text.substring(with: token.range),
                                                   display: display, theme: theme)
                else { continue }
                spans.append(.init(relativeLocation: tokens[i - 1].range.location - base,
                                   kind: .image(image)))
            case .inlineCode:
                guard i > 0, i + 1 < tokens.count,
                      tokens[i - 1].kind == .inlineCodeMarker,
                      tokens[i + 1].kind == .inlineCodeMarker else { continue }
                let content = (text.substring(with: token.range) as NSString)
                    .size(withAttributes: [.font: theme.monoFont]).width
                spans.append(.init(relativeLocation: tokens[i - 1].range.location - base,
                                   kind: .chip(width: content + OverlayLineFragment.chipPadding * 2)))
            default:
                continue
            }
        }
        return spans
    }

    // MARK: Table geometry

    static func cells(of line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = cells.first, first.isEmpty { cells.removeFirst() }
        if let last = cells.last, last.isEmpty { cells.removeLast() }
        return cells
    }

    /// Column widths shared across the whole table containing `lineIndex`,
    /// plus the header row's index (first row when followed by a delimiter).
    private func tableGeometry(for lineIndex: Int, scan: BlockScan, text: NSString) -> ([CGFloat], Int?) {
        func isTableLine(_ i: Int) -> Bool {
            switch scan.lines[i].kind {
            case .tableRow, .tableDelimiterRow: return true
            default: return false
            }
        }
        var first = lineIndex
        var last = lineIndex
        while first > 0, isTableLine(first - 1) { first -= 1 }
        while last < scan.lines.count - 1, isTableLine(last + 1) { last += 1 }

        var headerIndex: Int?
        if case .tableRow = scan.lines[first].kind,
           first + 1 <= last, case .tableDelimiterRow = scan.lines[first + 1].kind {
            headerIndex = first
        }

        let font = theme.baseFont
        var widths: [CGFloat] = []
        for i in first...last {
            guard case .tableRow = scan.lines[i].kind else { continue }
            let cells = Self.cells(of: text.substring(with: scan.lines[i].contentRange))
            for (index, cell) in cells.enumerated() {
                let w = (cell as NSString).size(withAttributes: [.font: font]).width + 26
                if index >= widths.count {
                    widths.append(max(w, 64))
                } else {
                    widths[index] = max(widths[index], max(w, 64))
                }
            }
        }
        return (widths, headerIndex)
    }
}

// MARK: - NSTextLayoutManagerDelegate

extension LivePreviewLayoutController: @preconcurrency NSTextLayoutManagerDelegate {
    public func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let standard = NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        guard let contentStorage,
              let elementRange = textElement.elementRange,
              let storage = contentStorage.textStorage else { return standard }

        let charIndex = contentStorage.offset(from: contentStorage.documentRange.location,
                                              to: elementRange.location)
        let text = storage.string as NSString

        switch role(forLineAt: charIndex, text: text) {
        case .plain:
            return standard
        case .code(let roundTop, let roundBottom):
            return CodeBandFragment(textElement: textElement, range: elementRange, theme: theme,
                                    roundTop: roundTop, roundBottom: roundBottom)
        case .image(let path):
            if let image = imageProvider.image(forPath: path) {
                return ImageLineFragment(textElement: textElement, range: elementRange,
                                         theme: theme, image: image)
            }
            return standard
        case .math(let latex):
            if let image = MathRenderer.image(latex: latex, fontSize: theme.baseFontSize + 3,
                                              textColor: theme.textColor) {
                return ImageLineFragment(textElement: textElement, range: elementRange,
                                         theme: theme, image: image, isMath: true)
            }
            return standard
        case .overlays(let spans):
            return OverlayLineFragment(textElement: textElement, range: elementRange,
                                       theme: theme, spans: spans)
        case .tableRow(let cells, let isHeader, let columns):
            return TableRowFragment(textElement: textElement, range: elementRange, theme: theme,
                                    cells: cells, isHeader: isHeader, columns: columns)
        case .tableDelimiter:
            return TableDelimiterFragment(textElement: textElement, range: elementRange, theme: theme)
        case .quote:
            return QuoteBarFragment(textElement: textElement, range: elementRange, theme: theme)
        case .rule:
            return RuleFragment(textElement: textElement, range: elementRange, theme: theme)
        }
    }
}
