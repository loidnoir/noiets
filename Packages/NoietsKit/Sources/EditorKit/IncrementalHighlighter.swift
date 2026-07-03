import AppKit
import MarkdownKit
import RenderKit
import SharedModel

public extension NSAttributedString.Key {
    /// Marks a run Live Preview has collapsed (rendered invisible). Used for
    /// caret snapping; never serialized (attributes don't affect copied text).
    static let noietsHidden = NSAttributedString.Key("noietsHidden")
}

/// Applies syntax styling to the raw markdown in the text storage, driven by
/// NSTextStorageDelegate. Per keystroke it re-scans block structure (cheap,
/// line-level) and restyles only the lines whose tokens can have changed
/// (edited lines ∪ structure-diff span) — O(paragraph) for normal typing.
///
/// Styling is display-only: attributes are applied outside the
/// shouldChangeText/didChangeText path so they never enter the undo stack.
@MainActor
public final class IncrementalHighlighter: NSObject {
    public let theme: EditorTheme

    /// The paragraph range(s) the selection touches. Lines intersecting it
    /// render as raw source (markers visible); everything else hides markup.
    public private(set) var activeParagraphRange = NSRange(location: 0, length: 0)

    /// Set while the user composes marked text (IME) — styling pauses.
    public weak var textView: NSTextView?

    /// Escape hatch: disables hiding entirely (plain highlight mode).
    public var livePreviewEnabled = true

    private var scan: BlockScan?
    private var signature: [Int] = []
    private let codeEngine = BuiltinCodeHighlighter()

    /// Read access for the layout controller (fragment classification).
    public var currentScan: BlockScan? { scan }

    /// Font used to collapse hidden runs to (near) zero width while keeping
    /// character indices intact.
    private static let collapsedFont = NSFont.systemFont(ofSize: 0.1)

    public init(theme: EditorTheme) {
        self.theme = theme
        super.init()
    }

    // MARK: Entry points

    /// Restyles the whole document (initial load).
    public func restyleAll(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        let newScan = BlockScan.scan(text)
        scan = newScan
        signature = newScan.structureSignature
        guard !newScan.lines.isEmpty else { return }
        storage.beginEditing()
        applyStyles(storage, text: text, scan: newScan, lineSpan: 0...(newScan.lines.count - 1))
        storage.endEditing()
    }

    /// Moves the active (raw-source) paragraph after a selection change and
    /// restyles only the lines whose active state flipped. Tables activate as
    /// a whole — entering any row reverts the entire table to source (and its
    /// grid fragments regenerate), like Obsidian.
    public func updateActiveParagraph(_ storage: NSTextStorage, to newRange: NSRange) {
        let expanded = expandRangeToTable(newRange, text: storage.string as NSString)
        guard expanded != activeParagraphRange else { return }
        let oldRange = activeParagraphRange
        activeParagraphRange = expanded
        guard let scan, storage.length > 0 else { return }

        var spans: [ClosedRange<Int>] = []
        if oldRange.location <= storage.length {
            spans.append(scan.lineIndices(intersecting: oldRange))
        }
        spans.append(scan.lineIndices(intersecting: expanded))
        for span in spans {
            let clamped = min(span.lowerBound, scan.lines.count - 1)...min(span.upperBound, scan.lines.count - 1)
            applyStyles(storage, text: storage.string as NSString, scan: scan, lineSpan: clamped)
        }
    }

    /// If the selection touches a table, a $$ math block, or a code fence
    /// block, expand to the whole run — those render as one unit and revert
    /// to source together (fence backticks reappear while inside the block).
    private func expandRangeToTable(_ range: NSRange, text: NSString) -> NSRange {
        guard let scan, !scan.lines.isEmpty, text.length > 0 else { return range }
        let span = scan.lineIndices(intersecting: range)
        func isTable(_ i: Int) -> Bool {
            switch scan.lines[i].kind {
            case .tableRow, .tableDelimiterRow, .mathDelimiter, .mathBlockContent,
                 .code, .fenceDelimiter:
                return true
            default: return false
            }
        }
        var first = min(span.lowerBound, scan.lines.count - 1)
        var last = min(span.upperBound, scan.lines.count - 1)
        guard isTable(first) || isTable(last) else { return range }
        while first > 0, isTable(first - 1) { first -= 1 }
        while last < scan.lines.count - 1, isTable(last + 1) { last += 1 }
        if !isTable(first) { first = min(first + 1, last) }
        let start = scan.lines[first].range.location
        let end = scan.lines[last].range.location + scan.lines[last].range.length
        return NSRange(location: min(start, range.location),
                       length: max(end, range.location + range.length) - min(start, range.location))
    }

    /// Called from didProcessEditing after a character edit.
    fileprivate func processEdit(_ storage: NSTextStorage, editedRange: NSRange) {
        if textView?.hasMarkedText() == true { return } // don't disturb IME composition
        let text = storage.string as NSString
        let newScan = BlockScan.scan(text)
        let newSignature = newScan.structureSignature

        let structureSpan = SignatureDiff.changedLineSpan(old: signature, new: newSignature)
        let editedLines = newScan.lineIndices(intersecting: editedRange)

        var first = editedLines.lowerBound
        // +1: a newline inserted mid-line splits it — the second half is a new
        // line whose tokens changed, but ends-diff over repeated structure IDs
        // can misattribute which twin is new. Covering one line past the edit
        // makes splits always safe.
        var last = editedLines.upperBound + 1
        if !structureSpan.isEmpty {
            first = min(first, structureSpan.lowerBound)
            last = max(last, structureSpan.upperBound - 1)
        }
        first = max(0, min(first, newScan.lines.count - 1))
        last = max(first, min(last, newScan.lines.count - 1))

        scan = newScan
        signature = newSignature
        applyStyles(storage, text: text, scan: newScan, lineSpan: first...last)
    }

    // MARK: Styling

    private func applyStyles(
        _ storage: NSTextStorage,
        text: NSString,
        scan: BlockScan,
        lineSpan: ClosedRange<Int>
    ) {
        guard !scan.lines.isEmpty else { return }
        let firstLine = scan.lines[lineSpan.lowerBound]
        let lastLine = scan.lines[lineSpan.upperBound]
        let fullRange = NSRange(
            location: firstLine.range.location,
            length: lastLine.range.location + lastLine.range.length - firstLine.range.location
        )
        guard fullRange.length > 0 || storage.length == 0 else { return }

        // Reset to base, then layer token styles on top.
        storage.setAttributes(theme.typingAttributes(), range: fullRange)

        for index in lineSpan {
            let line = scan.lines[index]
            styleLine(storage, text: text, line: line)
        }
    }

    private func styleLine(_ storage: NSTextStorage, text: NSString, line: BlockScan.Line) {
        // Line-level treatments first.
        switch line.kind {
        case .heading(let level, _, _):
            storage.addAttribute(.paragraphStyle, value: theme.headingParagraphStyle(level: level),
                                 range: line.range)
        case .code, .fenceDelimiter, .tableRow, .tableDelimiterRow, .frontmatterContent, .frontmatterDelimiter:
            if line.contentRange.length > 0 {
                storage.addAttribute(.font, value: theme.monoFont, range: line.contentRange)
            }
        case .blockquote:
            // Quotes read quieter than body text.
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: line.range)
        default:
            break
        }

        let tokens = MarkdownScan.lineTokens(text, line: line)
        for token in tokens {
            apply(token, storage: storage)
        }

        // Completed tasks read as done: mute + strike the content.
        if case .listItem(_, _, let task, let contentStart) = line.kind, task?.checked == true {
            let end = line.contentRange.location + line.contentRange.length
            if contentStart < end {
                let range = NSRange(location: contentStart, length: end - contentStart)
                storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        // Live Preview: on inactive lines, collapse the markup runs.
        let isActive = !livePreviewEnabled
            || NSIntersectionRange(line.range, activeParagraphRange).length > 0
            || (activeParagraphRange.length == 0
                && activeParagraphRange.location >= line.range.location
                && activeParagraphRange.location <= line.range.location + line.range.length)
        if !isActive {
            // Rendered quotes indent to the list-text column ("> " collapses).
            if case .blockquote = line.kind {
                let indent = ("- " as NSString).size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: theme.baseFontSize, weight: .bold),
                ]).width
                let style = (theme.defaultParagraphStyle.mutableCopy() as? NSMutableParagraphStyle)
                    ?? NSMutableParagraphStyle()
                style.firstLineHeadIndent = indent
                style.headIndent = indent
                storage.addAttribute(.paragraphStyle, value: style, range: line.range)
            }
            // Math collapses only on lines whose fragment draws overlays
            // (OverlayLineFragment); elsewhere it stays styled source.
            let collapseMath: Bool
            switch line.kind {
            case .paragraph, .listItem: collapseMath = true
            default: collapseMath = false
            }
            hideMarkup(tokens: tokens, storage: storage, text: text, collapseMath: collapseMath)
        }
    }

    /// Applies the collapsed rendering to every token that hides in preview,
    /// and makes links/tags clickable (inactive lines only — the active line
    /// is raw source where clicks should place the caret).
    private func hideMarkup(tokens: [Token], storage: NSTextStorage, text: NSString,
                            collapseMath: Bool) {
        func hide(_ range: NSRange) {
            storage.addAttribute(.font, value: Self.collapsedFont, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            storage.addAttribute(.noietsHidden, value: true, range: range)
        }
        func link(_ range: NSRange, _ url: String) {
            storage.addAttribute(.link, value: url, range: range)
            storage.addAttribute(.cursor, value: NSCursor.pointingHand, range: range)
        }
        func noiets(_ kind: String, _ value: String) -> String {
            "noiets://\(kind)/\(value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value)"
        }

        for (index, token) in tokens.enumerated() {
            if case .inlineCodeMarker = token.kind {
                // Backticks go invisible and shrink to the chip's side
                // padding; the rounded chip itself is drawn behind the span
                // by OverlayLineFragment.
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: token.range)
                let advance = ("`" as NSString)
                    .size(withAttributes: [.font: theme.monoFont]).width
                storage.addAttribute(.kern,
                                     value: OverlayLineFragment.chipPadding - advance,
                                     range: token.range)
                continue
            }
            if token.kind.hiddenInPreview {
                hide(token.range)
                continue
            }
            switch token.kind {
            case .linkURL:
                if index > 0, tokens[index - 1].kind == .linkBracket {
                    // The URL of [text](url): hidden, and the text becomes the link.
                    hide(token.range)
                } else {
                    // Bare autolink: clickable as itself.
                    link(token.range, text.substring(with: token.range))
                }
            case .linkText:
                // Find this link's URL (two tokens ahead: text, ](, url).
                if index + 2 < tokens.count, tokens[index + 2].kind == .linkURL {
                    link(token.range, text.substring(with: tokens[index + 2].range))
                }
            case .wikiLinkTarget:
                if index + 2 < tokens.count, tokens[index + 2].kind == .wikiLinkAlias {
                    hide(token.range) // aliased: only the alias shows…
                } else {
                    link(token.range, noiets("open", text.substring(with: token.range)))
                }
            case .wikiLinkAlias:
                // …and the alias navigates to the target (two tokens back).
                if index >= 2, tokens[index - 2].kind == .wikiLinkTarget {
                    link(token.range, noiets("open", text.substring(with: tokens[index - 2].range)))
                }
            case .tagName:
                link(token.range, noiets("tag", text.substring(with: token.range)))
            case .listMarker(ordered: false):
                // "- " collapses; a round dot draws in the reserved gap. On
                // task rows the check circle is the marker, so the dash just
                // collapses with no reserved width.
                hide(token.range)
                let isTask = tokens.contains {
                    if case .taskMarker = $0.kind { return true }
                    return false
                }
                if isTask { break }
                let bold = NSFont.systemFont(ofSize: theme.baseFontSize, weight: .bold)
                let marker = text.substring(with: token.range) as NSString
                let kern = max(0, marker.size(withAttributes: [.font: bold]).width
                    - marker.size(withAttributes: [.font: Self.collapsedFont]).width)
                storage.addAttribute(.kern, value: kern,
                                     range: NSRange(location: token.range.location + token.range.length - 1,
                                                    length: 1))
            case .taskMarker:
                // "[ ]" / "[x]" collapses; a check circle draws in the gap.
                // Reserve the footprint of a bullet row ("- " minus the real
                // space that follows "]") so text starts align across lists.
                hide(token.range)
                let bold = NSFont.systemFont(ofSize: theme.baseFontSize, weight: .bold)
                let dashWidth = ("- " as NSString).size(withAttributes: [.font: bold]).width
                let spaceWidth = (" " as NSString).size(withAttributes: [.font: theme.baseFont]).width
                let marker = text.substring(with: token.range) as NSString
                let kern = max(0, dashWidth - spaceWidth
                    - marker.size(withAttributes: [.font: Self.collapsedFont]).width)
                storage.addAttribute(.kern, value: kern,
                                     range: NSRange(location: token.range.location + token.range.length - 1,
                                                    length: 1))
            case .blockquoteMarker:
                hide(token.range) // the quote bar carries the meaning
            case .codeFenceDelimiter:
                // Backticks go invisible with zero advance (negative kern),
                // keeping the mono font so the fence lines never change
                // height — the language label sits at the line start, and
                // the caret inside the block reveals the raw fences.
                let ticks = NSRange(location: token.range.location,
                                    length: min(3, token.range.length))
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: ticks)
                let advance = ("`" as NSString)
                    .size(withAttributes: [.font: theme.monoFont]).width
                storage.addAttribute(.kern, value: -advance, range: ticks)
            case .mathContent(let display):
                // Inline $…$ / $$…$$: collapse the whole span and reserve the
                // typeset image's width with a kern on the closing marker; the
                // OverlayLineFragment draws the image over the gap.
                guard collapseMath, index > 0, index + 1 < tokens.count,
                      tokens[index - 1].kind == .mathMarker,
                      tokens[index + 1].kind == .mathMarker,
                      let image = InlineMath.image(latex: text.substring(with: token.range),
                                                   display: display, theme: theme)
                else { break }
                hide(token.range)
                let open = tokens[index - 1].range
                let close = tokens[index + 1].range
                let span = NSRange(location: open.location,
                                   length: close.location + close.length - open.location)
                let natural = (text.substring(with: span) as NSString)
                    .size(withAttributes: [.font: Self.collapsedFont]).width
                let kern = max(0, InlineMath.reservedWidth(for: image) - natural)
                storage.addAttribute(.kern, value: kern,
                                     range: NSRange(location: span.location + span.length - 1,
                                                    length: 1))
            default:
                break
            }
        }
    }

    private func apply(_ token: Token, storage: NSTextStorage) {
        let range = token.range
        switch token.kind {
        case .headingMarker(let level):
            storage.addAttribute(.font, value: theme.headingFont(level: level), range: range)
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)
        case .headingText(let level):
            storage.addAttribute(.font, value: theme.headingFont(level: level), range: range)

        case .bold:
            addTraits(.bold, storage: storage, range: range)
        case .italic:
            addTraits(.italic, storage: storage, range: range)
        case .boldItalic:
            addTraits([.bold, .italic], storage: storage, range: range)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)
        case .highlight:
            storage.addAttribute(.backgroundColor, value: theme.highlightBackground, range: range)
        case .emphasisMarker:
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)

        case .inlineCode:
            storage.addAttribute(.font, value: theme.monoFont, range: range)
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)
        case .inlineCodeMarker:
            storage.addAttribute(.font, value: theme.monoFont, range: range)
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)

        case .linkBracket:
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)
        case .linkText, .linkURL, .wikiLinkTarget, .wikiLinkAlias:
            storage.addAttribute(.foregroundColor, value: theme.accentColor, range: range)
        case .wikiLinkMarker:
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)

        case .tagMarker:
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)
        case .tagName:
            storage.addAttribute(.foregroundColor, value: theme.accentColor, range: range)

        case .mathMarker:
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)
        case .mathContent:
            storage.addAttribute(.foregroundColor, value: theme.codeColor, range: range)
            addTraits(.italic, storage: storage, range: range)

        case .listMarker(let ordered):
            storage.addAttribute(.foregroundColor, value: theme.accentColor, range: range)
            if ordered {
                storage.addAttribute(.font,
                                     value: NSFont.systemFont(ofSize: theme.baseFontSize,
                                                              weight: .medium),
                                     range: range)
            } else {
                addTraits(.bold, storage: storage, range: range)
            }
        case .taskMarker(let checked):
            storage.addAttribute(.font, value: theme.monoFont, range: range)
            storage.addAttribute(.foregroundColor,
                                 value: checked ? theme.mutedColor : theme.accentColor,
                                 range: range)
        case .blockquoteMarker:
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)

        case .codeFenceDelimiter, .frontmatterDelimiter, .horizontalRule,
             .tablePipe, .tableDelimiterRow:
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)
        case .codeContent(let language):
            storage.addAttribute(.foregroundColor, value: theme.textColor, range: range)
            if let language, codeEngine.supports(language: language) {
                let line = (storage.string as NSString).substring(with: range)
                for span in codeEngine.spans(forLine: line, language: language) {
                    let absolute = NSRange(location: range.location + span.range.location,
                                           length: span.range.length)
                    guard absolute.location + absolute.length <= range.location + range.length else { continue }
                    storage.addAttribute(.foregroundColor, value: color(for: span.kind), range: absolute)
                }
            }
        case .frontmatterContent:
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)
        }
    }

    private func color(for kind: CodeSpanKind) -> NSColor {
        switch kind {
        case .keyword: return theme.codeKeyword
        case .type: return theme.codeType
        case .string: return theme.codeString
        case .comment: return theme.codeComment
        case .number: return theme.codeNumber
        case .property: return theme.codeType
        }
    }

    /// Merges font traits with whatever font is already applied (so italic
    /// inside bold yields bold-italic).
    private func addTraits(_ traits: NSFontDescriptor.SymbolicTraits, storage: NSTextStorage, range: NSRange) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let font = (value as? NSFont) ?? theme.baseFont
            let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(traits)
            )
            if let merged = NSFont(descriptor: descriptor, size: font.pointSize) {
                storage.addAttribute(.font, value: merged, range: subRange)
            }
        }
    }
}

// MARK: - NSTextStorageDelegate

extension IncrementalHighlighter: NSTextStorageDelegate {
    public nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Text storage delegate callbacks fire on the mutating thread — always
        // main in this app. NSTextStorage isn't Sendable, hence the unsafe hop.
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated {
            processEdit(storage, editedRange: editedRange)
        }
    }
}
