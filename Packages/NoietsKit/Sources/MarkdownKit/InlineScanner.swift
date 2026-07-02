import Foundation
import SharedModel

/// Single-pass inline tokenizer for one line (or sub-range of a line).
/// Error-tolerant: anything unmatched stays literal text. Emits delimiter
/// tokens separately from content tokens so Live Preview can hide markers.
public enum InlineScanner {
    public static func tokens(_ text: NSString, in range: NSRange) -> [Token] {
        var ctx = Context(text: text, start: range.location, end: range.location + range.length)
        ctx.scan()
        return ctx.tokens.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Context

    private struct Context {
        let text: NSString
        let start: Int
        let end: Int
        var tokens: [Token] = []
        /// Ranges already claimed by closing markers / URLs; the scan skips them.
        var reserved: [NSRange] = []

        mutating func scan() {
            var i = start
            while i < end {
                if let r = reservedRange(at: i) {
                    i = r.location + r.length
                    continue
                }
                let c = text.character(at: i)
                var next: Int?
                switch c {
                case ch("\\"):
                    next = i + 2 // escape: skip next char
                case ch("`"):
                    next = codeSpan(at: i)
                case ch("$"):
                    next = math(at: i)
                case ch("["):
                    next = wikiLink(at: i) ?? markdownLink(at: i, isImage: false)
                case ch("!"):
                    next = markdownLink(at: i, isImage: true)
                case ch("*"), ch("_"):
                    next = emphasis(at: i, delimiter: c)
                case ch("~"):
                    next = pairedStyle(at: i, delimiter: c, kind: .strikethrough)
                case ch("="):
                    next = pairedStyle(at: i, delimiter: c, kind: .highlight)
                case ch("#"):
                    next = tag(at: i)
                case ch("h"):
                    next = autolink(at: i)
                default:
                    break
                }
                i = next ?? (i + 1)
            }
        }

        // MARK: Helpers

        func reservedRange(at i: Int) -> NSRange? {
            reserved.first { i >= $0.location && i < $0.location + $0.length }
        }

        mutating func emit(_ kind: TokenKind, _ range: NSRange) {
            guard range.length > 0 else { return }
            tokens.append(Token(kind, range))
        }

        func char(_ i: Int) -> unichar {
            text.character(at: i)
        }

        func isSpace(_ i: Int) -> Bool {
            guard i >= start, i < end else { return true } // line edges count as space
            let c = char(i)
            return c == 0x20 || c == 0x09
        }

        func isWordChar(_ i: Int) -> Bool {
            guard i >= start, i < end else { return false }
            let c = char(i)
            return (c >= ch("a") && c <= ch("z")) || (c >= ch("A") && c <= ch("Z"))
                || (c >= ch("0") && c <= ch("9")) || c == ch("_")
        }

        func runLength(of c: unichar, at i: Int) -> Int {
            var j = i
            while j < end, char(j) == c { j += 1 }
            return j - i
        }

        func isEscaped(_ i: Int) -> Bool {
            var backslashes = 0
            var j = i - 1
            while j >= start, char(j) == ch("\\") {
                backslashes += 1
                j -= 1
            }
            return backslashes % 2 == 1
        }

        // MARK: Code spans (highest precedence)

        mutating func codeSpan(at i: Int) -> Int? {
            let openLen = runLength(of: ch("`"), at: i)
            var j = i + openLen
            while j < end {
                if char(j) == ch("`") {
                    let closeLen = runLength(of: ch("`"), at: j)
                    if closeLen == openLen {
                        emit(.inlineCodeMarker, NSRange(location: i, length: openLen))
                        emit(.inlineCode, NSRange(location: i + openLen, length: j - i - openLen))
                        emit(.inlineCodeMarker, NSRange(location: j, length: closeLen))
                        return j + closeLen
                    }
                    j += closeLen
                } else {
                    j += 1
                }
            }
            return nil // unmatched: literal backticks
        }

        // MARK: Math

        mutating func math(at i: Int) -> Int? {
            guard !isEscaped(i) else { return nil }
            let display = i + 1 < end && char(i + 1) == ch("$")
            let markerLen = display ? 2 : 1
            let contentStart = i + markerLen
            guard contentStart < end else { return nil }
            if !display {
                // No space right after the opening $, and content can't open with a digit-only run
                if isSpace(contentStart) { return nil }
            }
            var j = contentStart
            while j < end {
                if char(j) == ch("$"), !isEscaped(j) {
                    if display {
                        if j + 1 < end, char(j + 1) == ch("$"), j > contentStart {
                            emit(.mathMarker, NSRange(location: i, length: 2))
                            emit(.mathContent(display: true), NSRange(location: contentStart, length: j - contentStart))
                            emit(.mathMarker, NSRange(location: j, length: 2))
                            return j + 2
                        }
                        j += 1
                        continue
                    }
                    // inline $: no space before the closing $, non-empty content
                    if j > contentStart, !isSpace(j - 1) {
                        let content = NSRange(location: contentStart, length: j - contentStart)
                        if !isAllCurrency(content) {
                            emit(.mathMarker, NSRange(location: i, length: 1))
                            emit(.mathContent(display: false), content)
                            emit(.mathMarker, NSRange(location: j, length: 1))
                            return j + 1
                        }
                        return nil
                    }
                    return nil
                }
                j += 1
            }
            return nil
        }

        /// "$5" / "$1,299.99" style content is money, not math.
        func isAllCurrency(_ range: NSRange) -> Bool {
            for i in range.location..<(range.location + range.length) {
                let c = char(i)
                let isDigit = c >= ch("0") && c <= ch("9")
                if !isDigit, c != ch(","), c != ch("."), c != 0x20 { return false }
            }
            return true
        }

        // MARK: Wiki links

        mutating func wikiLink(at i: Int) -> Int? {
            guard i + 1 < end, char(i + 1) == ch("[") else { return nil }
            let targetStart = i + 2
            var j = targetStart
            var pipe: Int?
            while j + 1 < end {
                let c = char(j)
                if c == ch("]"), char(j + 1) == ch("]") {
                    guard j > targetStart else { return nil } // [[]] stays literal
                    emit(.wikiLinkMarker, NSRange(location: i, length: 2))
                    if let pipe {
                        emit(.wikiLinkTarget, NSRange(location: targetStart, length: pipe - targetStart))
                        emit(.wikiLinkMarker, NSRange(location: pipe, length: 1))
                        emit(.wikiLinkAlias, NSRange(location: pipe + 1, length: j - pipe - 1))
                    } else {
                        emit(.wikiLinkTarget, NSRange(location: targetStart, length: j - targetStart))
                    }
                    emit(.wikiLinkMarker, NSRange(location: j, length: 2))
                    return j + 2
                }
                if c == ch("|"), pipe == nil { pipe = j }
                if c == ch("[") { return nil } // nested open: bail, stay literal
                j += 1
            }
            return nil
        }

        // MARK: Markdown links / images

        mutating func markdownLink(at i: Int, isImage: Bool) -> Int? {
            var bracketStart = i
            if isImage {
                guard i + 1 < end, char(i + 1) == ch("[") else { return nil }
                bracketStart = i + 1
                // ![[ is an Obsidian embed — treat as wiki link from the bracket
                if bracketStart + 1 < end, char(bracketStart + 1) == ch("[") { return nil }
            }
            let textStart = bracketStart + 1
            var j = textStart
            var depth = 0
            while j < end {
                let c = char(j)
                if c == ch("["), !isEscaped(j) { depth += 1 }
                if c == ch("]"), !isEscaped(j) {
                    if depth > 0 { depth -= 1; j += 1; continue }
                    break
                }
                j += 1
            }
            guard j < end, char(j) == ch("]"),
                  j + 1 < end, char(j + 1) == ch("(") else { return nil }
            let urlStart = j + 2
            var k = urlStart
            var parenDepth = 0
            while k < end {
                let c = char(k)
                if c == ch("("), !isEscaped(k) { parenDepth += 1 }
                if c == ch(")"), !isEscaped(k) {
                    if parenDepth > 0 { parenDepth -= 1; k += 1; continue }
                    break
                }
                k += 1
            }
            guard k < end, char(k) == ch(")") else { return nil }

            emit(.linkBracket, NSRange(location: i, length: textStart - i)) // "[" or "!["
            emit(.linkText, NSRange(location: textStart, length: j - textStart))
            emit(.linkBracket, NSRange(location: j, length: 2)) // "]("
            emit(.linkURL, NSRange(location: urlStart, length: k - urlStart))
            emit(.linkBracket, NSRange(location: k, length: 1)) // ")"

            // Scan inside the link text (nested emphasis), skip the ](url) tail.
            reserved.append(NSRange(location: j, length: k - j + 1))
            return textStart
        }

        // MARK: Emphasis (* and _)

        mutating func emphasis(at i: Int, delimiter: unichar) -> Int? {
            guard !isEscaped(i) else { return nil }
            let run = runLength(of: delimiter, at: i)
            // Underscore emphasis requires a word boundary on the outside.
            if delimiter == ch("_"), isWordChar(i - 1) { return nil }

            var tryLen = min(run, 3)
            while tryLen >= 1 {
                let contentStart = i + tryLen
                // Opening run must be followed by non-space.
                if contentStart < end, !isSpace(contentStart),
                   let close = findClose(delimiter: delimiter, length: tryLen, from: contentStart) {
                    let kind: TokenKind = tryLen == 3 ? .boldItalic : (tryLen == 2 ? .bold : .italic)
                    emit(.emphasisMarker, NSRange(location: i, length: tryLen))
                    emit(kind, NSRange(location: contentStart, length: close - contentStart))
                    emit(.emphasisMarker, NSRange(location: close, length: tryLen))
                    reserved.append(NSRange(location: close, length: tryLen))
                    return contentStart // keep scanning inside for nesting
                }
                tryLen -= 1
            }
            return i + run // no match: skip the whole literal run
        }

        func findClose(delimiter: unichar, length: Int, from: Int) -> Int? {
            var j = from
            while j < end {
                if let r = reserved.first(where: { j >= $0.location && j < $0.location + $0.length }) {
                    j = r.location + r.length
                    continue
                }
                if char(j) == delimiter, !isEscaped(j) {
                    let run = runLength(of: delimiter, at: j)
                    if run >= length, !isSpace(j - 1), j > from {
                        if delimiter == ch("_"), isWordChar(j + run) { j += run; continue }
                        return j
                    }
                    j += run
                } else {
                    j += 1
                }
            }
            return nil
        }

        // MARK: ~~strike~~ and ==highlight==

        mutating func pairedStyle(at i: Int, delimiter: unichar, kind: TokenKind) -> Int? {
            guard !isEscaped(i),
                  runLength(of: delimiter, at: i) >= 2 else { return nil }
            let contentStart = i + 2
            guard contentStart < end, !isSpace(contentStart) else { return nil }
            var j = contentStart
            while j + 1 < end {
                if char(j) == delimiter, char(j + 1) == delimiter, !isEscaped(j), !isSpace(j - 1) {
                    emit(.emphasisMarker, NSRange(location: i, length: 2))
                    emit(kind, NSRange(location: contentStart, length: j - contentStart))
                    emit(.emphasisMarker, NSRange(location: j, length: 2))
                    reserved.append(NSRange(location: j, length: 2))
                    return contentStart
                }
                j += 1
            }
            return nil
        }

        // MARK: #tags

        mutating func tag(at i: Int) -> Int? {
            guard !isEscaped(i) else { return nil }
            // Must be preceded by start-of-range or whitespace.
            if i > start, !isSpace(i - 1) { return nil }
            var j = i + 1
            var hasNonDigit = false
            while j < end {
                let c = char(j)
                let isDigit = c >= ch("0") && c <= ch("9")
                let isLetter = (c >= ch("a") && c <= ch("z")) || (c >= ch("A") && c <= ch("Z")) || c > 0x7F
                let isExtra = c == ch("_") || c == ch("-") || c == ch("/")
                guard isDigit || isLetter || isExtra else { break }
                if !isDigit { hasNonDigit = true }
                j += 1
            }
            guard j > i + 1, hasNonDigit else { return nil }
            emit(.tagMarker, NSRange(location: i, length: 1))
            emit(.tagName, NSRange(location: i + 1, length: j - i - 1))
            return j
        }

        // MARK: Bare URLs

        mutating func autolink(at i: Int) -> Int? {
            if i > start, isWordChar(i - 1) { return nil }
            for prefix in ["https://", "http://"] {
                let p = prefix as NSString
                guard i + p.length < end,
                      text.substring(with: NSRange(location: i, length: p.length)) == prefix else { continue }
                var j = i + p.length
                while j < end {
                    let c = char(j)
                    if c == 0x20 || c == 0x09 || c == ch(")") || c == ch(">") || c == ch("\"") { break }
                    j += 1
                }
                // strip trailing punctuation
                while j > i + p.length {
                    let c = char(j - 1)
                    if c == ch(".") || c == ch(",") || c == ch(";") || c == ch(":") || c == ch("!") || c == ch("?") {
                        j -= 1
                    } else {
                        break
                    }
                }
                guard j > i + p.length else { return nil }
                emit(.linkURL, NSRange(location: i, length: j - i))
                return j
            }
            return nil
        }
    }

}

private func ch(_ s: String) -> unichar {
    (s as NSString).character(at: 0)
}
