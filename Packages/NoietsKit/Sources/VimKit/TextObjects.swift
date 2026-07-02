import Foundation

/// Text objects: `iw`, `aw`, `i"`, `i(`, `ip`, `it`, … Returns the affected
/// range plus whether the object is linewise (paragraphs).
public enum TextObjects {
    public struct Result: Equatable {
        public let range: NSRange
        public let linewise: Bool
    }

    public enum Kind: Equatable {
        case word(big: Bool)
        case quote(Character)      // " ' `
        case pair(Character)       // ( [ { — either side of the pair
        case paragraph
        case tag                   // <x>…</x>
    }

    /// Maps the key pressed after i/a to an object kind.
    public static func kind(for char: Character) -> Kind? {
        switch char {
        case "w": return .word(big: false)
        case "W": return .word(big: true)
        case "\"", "'", "`": return .quote(char)
        case "(", ")", "b": return .pair("(")
        case "[", "]": return .pair("[")
        case "{", "}", "B": return .pair("{")
        case "p": return .paragraph
        case "t": return .tag
        default: return nil
        }
    }

    public static func range(_ t: NSString, at caret: Int, kind: Kind, around: Bool) -> Result? {
        guard t.length > 0 else { return nil }
        let i = min(caret, t.length - 1)
        switch kind {
        case .word(let big):
            return word(t, at: i, big: big, around: around)
        case .quote(let q):
            return quote(t, at: i, quote: q, around: around)
        case .pair(let open):
            return pair(t, at: i, open: open, around: around)
        case .paragraph:
            return paragraph(t, at: i, around: around)
        case .tag:
            return tag(t, at: i, around: around)
        }
    }

    // MARK: Word

    private static func word(_ t: NSString, at i: Int, big: Bool, around: Bool) -> Result? {
        let cls = Motions.charClass(t.character(at: i), big: big)
        guard cls != .newline else { return nil }

        var start = i
        var end = i
        while start > 0, Motions.charClass(t.character(at: start - 1), big: big) == cls { start -= 1 }
        while end < t.length - 1, Motions.charClass(t.character(at: end + 1), big: big) == cls { end += 1 }
        var range = NSRange(location: start, length: end - start + 1)

        if around, cls != .blank {
            // aw: include trailing blanks, else leading blanks.
            var e = range.location + range.length
            var extended = false
            while e < t.length, Motions.isBlank(t.character(at: e)) { e += 1; extended = true }
            if extended {
                range.length = e - range.location
            } else {
                var s = range.location
                while s > 0, Motions.isBlank(t.character(at: s - 1)) { s -= 1 }
                range = NSRange(location: s, length: range.location + range.length - s)
            }
        }
        return Result(range: range, linewise: false)
    }

    // MARK: Quotes (line-local, like vim)

    private static func quote(_ t: NSString, at i: Int, quote: Character, around: Bool) -> Result? {
        let q = String(quote).utf16.first!
        let lineStart = Motions.lineStart(t, at: i)
        let lineEnd = Motions.lineContentEnd(t, at: i)

        // Collect unescaped quote positions on the line.
        var positions: [Int] = []
        var j = lineStart
        while j < lineEnd {
            if t.character(at: j) == q {
                var backslashes = 0
                var k = j - 1
                while k >= lineStart, t.character(at: k) == 0x5C { backslashes += 1; k -= 1 }
                if backslashes % 2 == 0 { positions.append(j) }
            }
            j += 1
        }
        // Pair them up; pick the pair containing (or after) the caret.
        var pairIndex = 0
        while pairIndex + 1 < positions.count {
            let open = positions[pairIndex]
            let close = positions[pairIndex + 1]
            if i <= close {
                if around {
                    return Result(range: NSRange(location: open, length: close - open + 1), linewise: false)
                }
                return Result(range: NSRange(location: open + 1, length: close - open - 1), linewise: false)
            }
            pairIndex += 2
        }
        return nil
    }

    // MARK: Bracket pairs

    private static func pair(_ t: NSString, at i: Int, open: Character, around: Bool) -> Result? {
        let openCh = String(open).utf16.first!
        let closeCh: unichar
        switch open {
        case "(": closeCh = ")".utf16.first!
        case "[": closeCh = "]".utf16.first!
        case "{": closeCh = "}".utf16.first!
        default: return nil
        }

        // Find enclosing open bracket (scanning back with depth), treating a
        // bracket under the caret as enclosing.
        var depth = 0
        var openPos: Int?
        var j = i
        if t.character(at: i) == openCh { openPos = i }
        if openPos == nil {
            j = i
            while j >= 0 {
                let c = t.character(at: j)
                if c == closeCh, j != i { depth += 1 }
                if c == openCh {
                    if depth == 0 { openPos = j; break }
                    depth -= 1
                }
                j -= 1
            }
        }
        guard let start = openPos else { return nil }

        depth = 0
        var closePos: Int?
        j = start
        while j < t.length {
            let c = t.character(at: j)
            if c == openCh { depth += 1 }
            if c == closeCh {
                depth -= 1
                if depth == 0 { closePos = j; break }
            }
            j += 1
        }
        guard let end = closePos, end >= i else { return nil }

        if around {
            return Result(range: NSRange(location: start, length: end - start + 1), linewise: false)
        }
        guard end - start > 1 else {
            return Result(range: NSRange(location: start + 1, length: 0), linewise: false)
        }
        return Result(range: NSRange(location: start + 1, length: end - start - 1), linewise: false)
    }

    // MARK: Paragraph (linewise)

    private static func paragraph(_ t: NSString, at i: Int, around: Bool) -> Result? {
        func isBlankLine(_ loc: Int) -> Bool {
            Motions.lineContentEnd(t, at: loc) == Motions.lineStart(t, at: loc)
        }

        var start = Motions.lineStart(t, at: i)
        let caretBlank = isBlankLine(i)
        // Walk up while lines share blankness with the caret line.
        while start > 0 {
            let prev = t.lineRange(for: NSRange(location: start - 1, length: 0)).location
            if isBlankLine(prev) != caretBlank { break }
            start = prev
        }
        var end = t.lineRange(for: NSRange(location: Motions.lineStart(t, at: i), length: 0))
        var endLoc = end.location + end.length
        while endLoc < t.length {
            if isBlankLine(endLoc) != caretBlank { break }
            end = t.lineRange(for: NSRange(location: endLoc, length: 0))
            endLoc = end.location + end.length
        }
        if around, !caretBlank {
            // ap: include trailing blank lines.
            while endLoc < t.length, isBlankLine(endLoc) {
                let r = t.lineRange(for: NSRange(location: endLoc, length: 0))
                endLoc = r.location + r.length
            }
        }
        return Result(range: NSRange(location: start, length: endLoc - start), linewise: true)
    }

    // MARK: Tags <x>…</x>

    private static func tag(_ t: NSString, at i: Int, around: Bool) -> Result? {
        let s = t as String
        guard let regex = try? NSRegularExpression(pattern: "<(/?)([A-Za-z][A-Za-z0-9-]*)[^<>]*?(/?)>") else {
            return nil
        }
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: t.length))

        // Track open tags with a stack; find the innermost pair containing the caret.
        var stack: [(name: String, open: NSRange)] = []
        var best: (open: NSRange, close: NSRange)?
        for m in matches {
            let isClose = m.range(at: 1).length > 0
            let selfClose = m.range(at: 3).length > 0
            if selfClose { continue }
            let name = t.substring(with: m.range(at: 2))
            if !isClose {
                stack.append((name, m.range))
            } else {
                while let last = stack.last {
                    stack.removeLast()
                    if last.name == name {
                        let openR = last.open
                        let closeR = m.range
                        if openR.location <= i, i < closeR.location + closeR.length {
                            // Innermost pair wins: only replace a candidate
                            // whose open tag starts earlier (is more outer).
                            if best == nil || openR.location > best!.open.location {
                                best = (openR, closeR)
                            }
                        }
                        break
                    }
                }
            }
        }
        guard let (openR, closeR) = best else { return nil }
        if around {
            return Result(
                range: NSRange(location: openR.location,
                               length: closeR.location + closeR.length - openR.location),
                linewise: false
            )
        }
        let innerStart = openR.location + openR.length
        return Result(range: NSRange(location: innerStart, length: closeR.location - innerStart),
                      linewise: false)
    }
}
