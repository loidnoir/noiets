import Foundation

/// Pure text motions over an NSString buffer, all UTF-16 indices. Matches vim
/// semantics: `j`/`k` are logical lines, words are [alnum_] runs vs punct runs,
/// normal-mode caret never rests past the last character of a line.
public enum Motions {
    // MARK: Character classes

    static func isWordChar(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            || c == 0x5F || c > 0x7F
    }

    static func isBlank(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
    static func isNewline(_ c: unichar) -> Bool { c == 0x0A }

    enum CharClass {
        case blank, word, punct, newline
    }

    static func charClass(_ c: unichar, big: Bool) -> CharClass {
        if isNewline(c) { return .newline }
        if isBlank(c) { return .blank }
        if big { return .word }
        return isWordChar(c) ? .word : .punct
    }

    // MARK: Line geometry

    public static func lineRange(_ t: NSString, at i: Int) -> NSRange {
        guard t.length > 0 else { return NSRange(location: 0, length: 0) }
        return t.lineRange(for: NSRange(location: min(i, t.length - 1), length: 0))
    }

    /// End of line content (position of the newline, or text end).
    public static func lineContentEnd(_ t: NSString, at i: Int) -> Int {
        let r = lineRange(t, at: i)
        var end = r.location + r.length
        if end > r.location, isNewline(t.character(at: end - 1)) { end -= 1 }
        return end
    }

    public static func lineStart(_ t: NSString, at i: Int) -> Int {
        lineRange(t, at: i).location
    }

    public static func firstNonBlank(_ t: NSString, at i: Int) -> Int {
        let start = lineStart(t, at: i)
        let end = lineContentEnd(t, at: i)
        var j = start
        while j < end, isBlank(t.character(at: j)) { j += 1 }
        return min(j, max(start, end - 1)) // all-blank line: rest on last blank
    }

    /// Clamp for normal mode: caret sits ON the last character, not after it.
    public static func clampToLine(_ t: NSString, _ i: Int, allowEnd: Bool = false) -> Int {
        let start = lineStart(t, at: i)
        let end = lineContentEnd(t, at: i)
        if allowEnd { return min(max(i, start), end) }
        return min(max(i, start), max(start, end - 1))
    }

    public static func column(_ t: NSString, of i: Int) -> Int {
        i - lineStart(t, at: i)
    }

    // MARK: Horizontal

    public static func left(_ t: NSString, from i: Int, count: Int) -> Int {
        max(lineStart(t, at: i), i - max(count, 1))
    }

    public static func right(_ t: NSString, from i: Int, count: Int, allowEnd: Bool = false) -> Int {
        let end = lineContentEnd(t, at: i)
        let limit = allowEnd ? end : max(lineStart(t, at: i), end - 1)
        return min(limit, i + max(count, 1))
    }

    // MARK: Vertical (logical lines, like vim's j/k)

    public static func vertical(_ t: NSString, from i: Int, lines: Int, goalColumn: Int) -> Int {
        guard t.length > 0 else { return 0 }
        var lineLoc = lineStart(t, at: i)
        var remaining = abs(lines)
        if lines > 0 {
            while remaining > 0 {
                let r = t.lineRange(for: NSRange(location: lineLoc, length: 0))
                let next = r.location + r.length
                if next >= t.length { break } // already on the last line
                lineLoc = next
                remaining -= 1
            }
        } else if lines < 0 {
            while remaining > 0, lineLoc > 0 {
                lineLoc = t.lineRange(for: NSRange(location: lineLoc - 1, length: 0)).location
                remaining -= 1
            }
        }
        let target = lineLoc + goalColumn
        return clampToLine(t, min(target, lineContentEnd(t, at: lineLoc)))
    }

    // MARK: Words

    public static func wordForward(_ t: NSString, from i: Int, count: Int, big: Bool) -> Int {
        var pos = i
        for _ in 0..<max(count, 1) {
            guard pos < t.length else { break }
            let cls = charClass(t.character(at: pos), big: big)
            // Skip the current run…
            if cls == .word || cls == .punct {
                while pos < t.length, charClass(t.character(at: pos), big: big) == cls { pos += 1 }
            }
            // …then whitespace (newlines count).
            while pos < t.length,
                  charClass(t.character(at: pos), big: big) == .blank
                    || charClass(t.character(at: pos), big: big) == .newline {
                pos += 1
            }
        }
        return min(pos, max(0, t.length - 1))
    }

    /// Exclusive end for `dw`-style operators: stops at end of line rather than
    /// eating the newline when the motion would cross it (vim behavior).
    public static func wordForwardForOperator(_ t: NSString, from i: Int, count: Int, big: Bool) -> Int {
        let raw = wordForwardRaw(t, from: i, count: count, big: big)
        let eol = lineContentEnd(t, at: i)
        if raw > eol, i < eol { return eol }
        return raw
    }

    /// Like wordForward but may return t.length (for operator spans).
    static func wordForwardRaw(_ t: NSString, from i: Int, count: Int, big: Bool) -> Int {
        var pos = i
        for _ in 0..<max(count, 1) {
            guard pos < t.length else { break }
            let cls = charClass(t.character(at: pos), big: big)
            if cls == .word || cls == .punct {
                while pos < t.length, charClass(t.character(at: pos), big: big) == cls { pos += 1 }
            }
            while pos < t.length,
                  charClass(t.character(at: pos), big: big) == .blank
                    || charClass(t.character(at: pos), big: big) == .newline {
                pos += 1
            }
        }
        return pos
    }

    public static func wordBackward(_ t: NSString, from i: Int, count: Int, big: Bool) -> Int {
        var pos = i
        for _ in 0..<max(count, 1) {
            guard pos > 0 else { break }
            pos -= 1
            while pos > 0, {
                let cls = charClass(t.character(at: pos), big: big)
                return cls == .blank || cls == .newline
            }() {
                pos -= 1
            }
            guard pos >= 0 else { break }
            let cls = charClass(t.character(at: pos), big: big)
            if cls == .word || cls == .punct {
                while pos > 0, charClass(t.character(at: pos - 1), big: big) == cls { pos -= 1 }
            }
        }
        return max(pos, 0)
    }

    public static func wordEnd(_ t: NSString, from i: Int, count: Int, big: Bool) -> Int {
        var pos = i
        for _ in 0..<max(count, 1) {
            guard pos < t.length - 1 else { break }
            pos += 1
            while pos < t.length, {
                let cls = charClass(t.character(at: pos), big: big)
                return cls == .blank || cls == .newline
            }() {
                pos += 1
            }
            guard pos < t.length else { pos = t.length - 1; break }
            let cls = charClass(t.character(at: pos), big: big)
            while pos < t.length - 1, charClass(t.character(at: pos + 1), big: big) == cls { pos += 1 }
        }
        return min(pos, max(0, t.length - 1))
    }

    // MARK: Document

    /// Line number is 1-based; nil means last line (G) / first line (gg).
    public static func gotoLine(_ t: NSString, line: Int?, last: Bool) -> Int {
        guard t.length > 0 else { return 0 }
        if let line {
            var loc = 0
            var n = 1
            while n < line, loc < t.length {
                let r = t.lineRange(for: NSRange(location: loc, length: 0))
                let next = r.location + r.length
                if next >= t.length { break }
                loc = next
                n += 1
            }
            return firstNonBlank(t, at: loc)
        }
        if last {
            return firstNonBlank(t, at: t.length - 1)
        }
        return firstNonBlank(t, at: 0)
    }

    // MARK: Paragraphs

    public static func paragraphForward(_ t: NSString, from i: Int, count: Int) -> Int {
        var pos = i
        for _ in 0..<max(count, 1) {
            var loc = lineStart(t, at: pos)
            var sawContent = false
            while loc < t.length {
                let r = t.lineRange(for: NSRange(location: loc, length: 0))
                let contentLen = lineContentEnd(t, at: loc) - r.location
                let isBlankLine = contentLen == 0
                if isBlankLine, sawContent, loc > pos {
                    pos = loc
                    break
                }
                if !isBlankLine { sawContent = true }
                let next = r.location + r.length
                if next >= t.length {
                    pos = max(0, t.length - 1)
                    break
                }
                loc = next
            }
            if loc >= t.length { pos = max(0, t.length - 1) }
        }
        return pos
    }

    public static func paragraphBackward(_ t: NSString, from i: Int, count: Int) -> Int {
        var pos = i
        for _ in 0..<max(count, 1) {
            var loc = lineStart(t, at: pos)
            var sawContent = false
            while loc > 0 {
                let prevLineStart = t.lineRange(for: NSRange(location: loc - 1, length: 0)).location
                let contentLen = lineContentEnd(t, at: prevLineStart) - prevLineStart
                let isBlankLine = contentLen == 0
                if isBlankLine, sawContent {
                    pos = prevLineStart
                    break
                }
                if !isBlankLine { sawContent = true }
                loc = prevLineStart
            }
            if loc == 0 { pos = 0 }
        }
        return pos
    }

    // MARK: Find on line (f F t T)

    public static func findOnLine(
        _ t: NSString, from i: Int, char: Character,
        forward: Bool, till: Bool, count: Int
    ) -> Int? {
        let needle = String(char) as NSString
        guard needle.length >= 1 else { return nil }
        let target = needle.character(at: 0)
        let start = lineStart(t, at: i)
        let end = lineContentEnd(t, at: i)
        var pos = i
        var remaining = max(count, 1)
        if forward {
            var j = pos + 1
            // For repeated `t`, step past the char we're already touching.
            while j < end {
                if t.character(at: j) == target {
                    remaining -= 1
                    if remaining == 0 {
                        return till ? j - 1 : j
                    }
                }
                j += 1
            }
        } else {
            var j = pos - 1
            while j >= start {
                if t.character(at: j) == target {
                    remaining -= 1
                    if remaining == 0 {
                        return till ? j + 1 : j
                    }
                }
                j -= 1
            }
        }
        return nil
    }

    // MARK: Bracket match (%)

    public static func matchBracket(_ t: NSString, from i: Int) -> Int? {
        let pairs: [unichar: (unichar, Bool)] = [
            ch("("): (ch(")"), true), ch(")"): (ch("("), false),
            ch("["): (ch("]"), true), ch("]"): (ch("["), false),
            ch("{"): (ch("}"), true), ch("}"): (ch("{"), false),
        ]
        // Find the first bracket at or after the caret on this line.
        let end = lineContentEnd(t, at: i)
        var pos = i
        var bracket: unichar = 0
        while pos < end {
            let c = t.character(at: pos)
            if pairs[c] != nil { bracket = c; break }
            pos += 1
        }
        guard bracket != 0, let (match, forward) = pairs[bracket] else { return nil }
        var depth = 0
        if forward {
            var j = pos
            while j < t.length {
                let c = t.character(at: j)
                if c == bracket { depth += 1 }
                if c == match {
                    depth -= 1
                    if depth == 0 { return j }
                }
                j += 1
            }
        } else {
            var j = pos
            while j >= 0 {
                let c = t.character(at: j)
                if c == bracket { depth += 1 }
                if c == match {
                    depth -= 1
                    if depth == 0 { return j }
                }
                j -= 1
            }
        }
        return nil
    }
}

private func ch(_ s: String) -> unichar {
    (s as NSString).character(at: 0)
}
