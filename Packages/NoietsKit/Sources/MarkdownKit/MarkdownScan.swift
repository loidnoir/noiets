import Foundation
import SharedModel

/// Facade combining the block scan with per-line inline tokens. This is the
/// edit-mode tokenizer API the highlighter consumes.
public enum MarkdownScan {
    /// All tokens for the lines at `lineIndices` of an existing block scan.
    public static func tokens(
        _ text: NSString,
        scan: BlockScan,
        lineIndices: ClosedRange<Int>
    ) -> [Token] {
        var tokens: [Token] = []
        for index in lineIndices where index < scan.lines.count {
            tokens.append(contentsOf: lineTokens(text, line: scan.lines[index]))
        }
        return tokens
    }

    /// Tokens for the whole document (reference implementation for tests).
    public static func fullTokens(_ text: NSString) -> [Token] {
        let scan = BlockScan.scan(text)
        guard !scan.lines.isEmpty else { return [] }
        return tokens(text, scan: scan, lineIndices: 0...(scan.lines.count - 1))
    }

    // MARK: Per-line assembly

    public static func lineTokens(_ text: NSString, line: BlockScan.Line) -> [Token] {
        var tokens: [Token] = []
        switch line.kind {
        case .blank:
            break

        case .heading(let level, let markerRange, let textRange):
            tokens.append(Token(.headingMarker(level: level), markerRange))
            if textRange.length > 0 {
                tokens.append(Token(.headingText(level: level), textRange))
                tokens.append(contentsOf: InlineScanner.tokens(text, in: textRange))
            }

        case .fenceDelimiter(let language):
            _ = language
            tokens.append(Token(.codeFenceDelimiter, line.contentRange))

        case .code(let language):
            if line.contentRange.length > 0 {
                tokens.append(Token(.codeContent(language: language), line.contentRange))
            }

        case .frontmatterDelimiter:
            tokens.append(Token(.frontmatterDelimiter, line.contentRange))

        case .frontmatterContent:
            if line.contentRange.length > 0 {
                tokens.append(Token(.frontmatterContent, line.contentRange))
            }

        case .listItem(let markerRange, let ordered, let task, let contentStart):
            tokens.append(Token(.listMarker(ordered: ordered), markerRange))
            if let task {
                tokens.append(Token(.taskMarker(checked: task.checked), task.range))
            }
            let contentEnd = line.contentRange.location + line.contentRange.length
            if contentStart < contentEnd {
                let contentRange = NSRange(location: contentStart, length: contentEnd - contentStart)
                tokens.append(contentsOf: InlineScanner.tokens(text, in: contentRange))
            }

        case .blockquote(let markerRange, let contentStart):
            tokens.append(Token(.blockquoteMarker, markerRange))
            let contentEnd = line.contentRange.location + line.contentRange.length
            if contentStart < contentEnd {
                let contentRange = NSRange(location: contentStart, length: contentEnd - contentStart)
                tokens.append(contentsOf: InlineScanner.tokens(text, in: contentRange))
            }

        case .horizontalRule:
            tokens.append(Token(.horizontalRule, line.contentRange))

        case .tableDelimiterRow:
            tokens.append(Token(.tableDelimiterRow, line.contentRange))

        case .tableRow:
            for i in line.contentRange.location..<(line.contentRange.location + line.contentRange.length) {
                if text.character(at: i) == unichar(UInt8(ascii: "|")) {
                    tokens.append(Token(.tablePipe, NSRange(location: i, length: 1)))
                }
            }
            tokens.append(contentsOf: InlineScanner.tokens(text, in: line.contentRange))

        case .paragraph:
            tokens.append(contentsOf: InlineScanner.tokens(text, in: line.contentRange))
        }
        return tokens
    }
}
