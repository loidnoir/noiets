import Foundation
import SharedModel

/// Line-level block classification of a whole document. Cheap enough to run on
/// every edit (no inline work, one pass over lines); inline tokens are computed
/// lazily per line by `InlineScanner`. All ranges are UTF-16 in the raw source.
public struct BlockScan: Sendable {
    public struct TaskMarker: Equatable, Sendable {
        public let checked: Bool
        public let range: NSRange // the "[x]" span
    }

    public enum LineKind: Equatable, Sendable {
        case blank
        case heading(level: Int, markerRange: NSRange, textRange: NSRange)
        case fenceDelimiter(language: String?)
        case code(language: String?)
        case mathDelimiter        // a `$$` line opening/closing a math block
        case mathBlockContent     // lines between $$ fences
        case frontmatterDelimiter
        case frontmatterContent
        case listItem(markerRange: NSRange, ordered: Bool, task: TaskMarker?, contentStart: Int)
        case blockquote(markerRange: NSRange, contentStart: Int)
        case horizontalRule
        case tableDelimiterRow
        case tableRow
        case paragraph

        /// Coarse structural identity used to detect when an edit changed block
        /// structure beyond the edited lines (fence toggles etc.). Ignores ranges.
        public var structureID: Int {
            switch self {
            case .blank: return 0
            case .heading(let level, _, _): return 10 + level
            // Fence/code IDs fold in the language so an info-string edit
            // restyles the block's code lines (their language token changes).
            case .fenceDelimiter(let language): return 2 &+ ((language?.hashValue ?? 0) &<< 8)
            case .code(let language): return 3 &+ ((language?.hashValue ?? 0) &<< 8)
            case .frontmatterDelimiter: return 4
            case .frontmatterContent: return 5
            case .listItem(_, let ordered, _, _): return ordered ? 7 : 6
            case .blockquote: return 8
            case .horizontalRule: return 9
            case .tableDelimiterRow: return 20
            case .tableRow: return 21
            case .paragraph: return 22
            case .mathDelimiter: return 30
            case .mathBlockContent: return 31
            }
        }
    }

    public struct Line: Equatable, Sendable {
        public let range: NSRange        // includes the trailing newline, if any
        public let contentRange: NSRange // excludes the trailing newline
        public let kind: LineKind
    }

    public let lines: [Line]

    // MARK: Scanning

    private enum State {
        case normal
        case fence(char: unichar, length: Int, language: String?)
        case math // inside a $$ … $$ block
    }

    public static func scan(_ text: NSString) -> BlockScan {
        var lines: [Line] = []
        let length = text.length
        let frontmatterEnd = Frontmatter.parse(in: text as String).map(\.range.length) ?? 0
        var state: State = .normal

        var location = 0
        while location < length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: location, length: 0))
            let range = NSRange(location: start, length: end - start)
            let contentRange = NSRange(location: start, length: contentsEnd - start)
            let kind = classify(
                text, contentRange: contentRange, state: &state,
                inFrontmatter: start < frontmatterEnd,
                isFrontmatterDelimiter: start == 0 || contentsEnd == frontmatterEnd - 1
                    || end == frontmatterEnd
            )
            lines.append(Line(range: range, contentRange: contentRange, kind: kind))
            if end == location { break } // safety
            location = end
        }
        if length == 0 {
            lines.append(Line(range: NSRange(location: 0, length: 0),
                              contentRange: NSRange(location: 0, length: 0),
                              kind: .blank))
        }
        return BlockScan(lines: lines)
    }

    private static func classify(
        _ text: NSString,
        contentRange: NSRange,
        state: inout State,
        inFrontmatter: Bool,
        isFrontmatterDelimiter: Bool
    ) -> LineKind {
        if inFrontmatter {
            return isFrontmatterDelimiter ? .frontmatterDelimiter : .frontmatterContent
        }

        // Inside a fenced code block: only a valid closing fence escapes.
        if case .fence(let char, let len, let language) = state {
            if isClosingFence(text, contentRange: contentRange, char: char, minLength: len) {
                state = .normal
                return .fenceDelimiter(language: nil)
            }
            return .code(language: language)
        }

        // Inside a $$ math block: only a closing $$ line escapes.
        if case .math = state {
            if isMathFenceLine(text, contentRange: contentRange) {
                state = .normal
                return .mathDelimiter
            }
            return .mathBlockContent
        }

        let trimmed = trimmedRange(text, contentRange)
        if trimmed.length == 0 { return .blank }

        // Opening $$ math fence (a line that is exactly `$$`).
        if isMathFenceLine(text, contentRange: contentRange) {
            state = .math
            return .mathDelimiter
        }

        // Opening fence.
        if let (char, len, language) = openingFence(text, contentRange: contentRange) {
            state = .fence(char: char, length: len, language: language)
            return .fenceDelimiter(language: language)
        }

        // ATX heading.
        if let heading = heading(text, contentRange: contentRange) {
            return heading
        }

        // Horizontal rule (checked before lists so "- - -" is an hr).
        if isHorizontalRule(text, trimmed) {
            return .horizontalRule
        }

        // Blockquote.
        if let quote = blockquote(text, contentRange: contentRange) {
            return quote
        }

        // List item (bullet or ordered).
        if let list = listItem(text, contentRange: contentRange) {
            return list
        }

        // Table rows: a line whose first non-space char is '|'.
        if text.character(at: trimmed.location) == unichar(UInt8(ascii: "|")) {
            return isTableDelimiterRow(text, trimmed) ? .tableDelimiterRow : .tableRow
        }

        return .paragraph
    }

    // MARK: Line predicates

    private static func trimmedRange(_ text: NSString, _ range: NSRange) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        while start < end, isSpaceOrTab(text.character(at: start)) { start += 1 }
        while end > start, isSpaceOrTab(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isSpaceOrTab(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09
    }

    private static func openingFence(_ text: NSString, contentRange: NSRange) -> (unichar, Int, String?)? {
        var i = contentRange.location
        let end = contentRange.location + contentRange.length
        var indent = 0
        while i < end, text.character(at: i) == 0x20, indent < 4 { i += 1; indent += 1 }
        guard indent <= 3, i < end else { return nil }
        let char = text.character(at: i)
        guard char == unichar(UInt8(ascii: "`")) || char == unichar(UInt8(ascii: "~")) else { return nil }
        var runEnd = i
        while runEnd < end, text.character(at: runEnd) == char { runEnd += 1 }
        let runLength = runEnd - i
        guard runLength >= 3 else { return nil }
        let info = text.substring(with: NSRange(location: runEnd, length: end - runEnd))
            .trimmingCharacters(in: .whitespaces)
        if char == unichar(UInt8(ascii: "`")), info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map { String($0).lowercased() }
        return (char, runLength, (language?.isEmpty ?? true) ? nil : language)
    }

    private static func isMathFenceLine(_ text: NSString, contentRange: NSRange) -> Bool {
        let trimmed = trimmedRange(text, contentRange)
        guard trimmed.length == 2 else { return false }
        return text.character(at: trimmed.location) == unichar(UInt8(ascii: "$"))
            && text.character(at: trimmed.location + 1) == unichar(UInt8(ascii: "$"))
    }

    private static func isClosingFence(_ text: NSString, contentRange: NSRange, char: unichar, minLength: Int) -> Bool {
        let trimmed = trimmedRange(text, contentRange)
        guard trimmed.length >= minLength else { return false }
        for i in trimmed.location..<(trimmed.location + trimmed.length) {
            if text.character(at: i) != char { return false }
        }
        return true
    }

    private static func heading(_ text: NSString, contentRange: NSRange) -> LineKind? {
        let start = contentRange.location
        let end = contentRange.location + contentRange.length
        var i = start
        while i < end, text.character(at: i) == unichar(UInt8(ascii: "#")) { i += 1 }
        let level = i - start
        guard level >= 1, level <= 6 else { return nil }
        if i < end {
            guard isSpaceOrTab(text.character(at: i)) else { return nil }
            i += 1
        }
        let markerRange = NSRange(location: start, length: i - start)
        let textRange = NSRange(location: i, length: end - i)
        return .heading(level: level, markerRange: markerRange, textRange: textRange)
    }

    private static func isHorizontalRule(_ text: NSString, _ trimmed: NSRange) -> Bool {
        guard trimmed.length >= 3 else { return false }
        var ruleChar: unichar = 0
        var count = 0
        for i in trimmed.location..<(trimmed.location + trimmed.length) {
            let c = text.character(at: i)
            if isSpaceOrTab(c) { continue }
            if c != unichar(UInt8(ascii: "-")), c != unichar(UInt8(ascii: "*")), c != unichar(UInt8(ascii: "_")) {
                return false
            }
            if ruleChar == 0 { ruleChar = c }
            guard c == ruleChar else { return false }
            count += 1
        }
        return count >= 3
    }

    private static func blockquote(_ text: NSString, contentRange: NSRange) -> LineKind? {
        var i = contentRange.location
        let end = contentRange.location + contentRange.length
        var indent = 0
        while i < end, text.character(at: i) == 0x20, indent < 4 { i += 1; indent += 1 }
        guard indent <= 3, i < end, text.character(at: i) == unichar(UInt8(ascii: ">")) else { return nil }
        let markerStart = i
        while i < end, text.character(at: i) == unichar(UInt8(ascii: ">")) {
            i += 1
            if i < end, text.character(at: i) == 0x20 { i += 1 }
        }
        return .blockquote(markerRange: NSRange(location: markerStart, length: i - markerStart), contentStart: i)
    }

    private static func listItem(_ text: NSString, contentRange: NSRange) -> LineKind? {
        var i = contentRange.location
        let end = contentRange.location + contentRange.length
        while i < end, isSpaceOrTab(text.character(at: i)) { i += 1 }
        guard i < end else { return nil }
        let markerStart = i
        let c = text.character(at: i)
        var ordered = false

        if c == unichar(UInt8(ascii: "-")) || c == unichar(UInt8(ascii: "*")) || c == unichar(UInt8(ascii: "+")) {
            i += 1
        } else if c >= unichar(UInt8(ascii: "0")), c <= unichar(UInt8(ascii: "9")) {
            var digits = 0
            while i < end, text.character(at: i) >= unichar(UInt8(ascii: "0")),
                  text.character(at: i) <= unichar(UInt8(ascii: "9")), digits < 9 {
                i += 1
                digits += 1
            }
            guard i < end, text.character(at: i) == unichar(UInt8(ascii: ".")) || text.character(at: i) == unichar(UInt8(ascii: ")")) else { return nil }
            i += 1
            ordered = true
        } else {
            return nil
        }

        guard i < end, isSpaceOrTab(text.character(at: i)) else { return nil }
        i += 1
        let markerRange = NSRange(location: markerStart, length: i - markerStart)

        // Optional task checkbox: "[ ] ", "[x] ", "[X] ".
        var task: TaskMarker?
        var contentStart = i
        if i + 3 <= end,
           text.character(at: i) == unichar(UInt8(ascii: "[")),
           text.character(at: i + 2) == unichar(UInt8(ascii: "]")) {
            let inner = text.character(at: i + 1)
            let isOpen = inner == 0x20
            let isDone = inner == unichar(UInt8(ascii: "x")) || inner == unichar(UInt8(ascii: "X"))
            let followedOK = i + 3 == end || isSpaceOrTab(text.character(at: i + 3))
            if (isOpen || isDone), followedOK {
                task = TaskMarker(checked: isDone, range: NSRange(location: i, length: 3))
                contentStart = min(i + 4, end)
            }
        }
        return .listItem(markerRange: markerRange, ordered: ordered, task: task, contentStart: contentStart)
    }

    private static func isTableDelimiterRow(_ text: NSString, _ trimmed: NSRange) -> Bool {
        var hasDash = false
        for i in trimmed.location..<(trimmed.location + trimmed.length) {
            switch text.character(at: i) {
            case unichar(UInt8(ascii: "|")), unichar(UInt8(ascii: ":")), 0x20, 0x09:
                continue
            case unichar(UInt8(ascii: "-")):
                hasDash = true
            default:
                return false
            }
        }
        return hasDash
    }

    // MARK: Lookup

    /// Index of the line containing `location` (binary search).
    public func lineIndex(containing location: Int) -> Int {
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            let line = lines[mid]
            if location < line.range.location {
                hi = mid - 1
            } else if location >= line.range.location + line.range.length, mid < lines.count - 1 {
                lo = mid + 1
            } else {
                return mid
            }
        }
        return lo
    }

    /// The line indices whose ranges intersect `range` (inclusive bounds).
    public func lineIndices(intersecting range: NSRange) -> ClosedRange<Int> {
        let first = lineIndex(containing: range.location)
        let last = lineIndex(containing: max(range.location, range.location + range.length - 1))
        return first...max(first, last)
    }

    public var structureSignature: [Int] { lines.map(\.kind.structureID) }
}
