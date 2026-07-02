import AppKit
import MarkdownKit
import SharedModel

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

    /// Live Preview (M2) flips marker tokens to hidden on inactive paragraphs;
    /// M1 keeps everything visible.
    private var scan: BlockScan?
    private var signature: [Int] = []

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

    /// Called from didProcessEditing after a character edit.
    fileprivate func processEdit(_ storage: NSTextStorage, editedRange: NSRange) {
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
        default:
            break
        }

        for token in MarkdownScan.lineTokens(text, line: line) {
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
            storage.addAttribute(.foregroundColor, value: theme.codeColor, range: range)
            storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: range)
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

        case .listMarker:
            storage.addAttribute(.foregroundColor, value: theme.accentColor, range: range)
            addTraits(.bold, storage: storage, range: range)
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
        case .codeContent:
            storage.addAttribute(.foregroundColor, value: theme.textColor, range: range)
        case .frontmatterContent:
            storage.addAttribute(.foregroundColor, value: theme.mutedColor, range: range)
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
