import Foundation
import Testing
@testable import MarkdownKit
import SharedModel

private func tokens(_ doc: String) -> [Token] {
    MarkdownScan.fullTokens(doc as NSString)
}

private func slice(_ doc: String, _ range: NSRange) -> String {
    (doc as NSString).substring(with: range)
}

private func first(_ doc: String, _ kind: TokenKind) -> String? {
    tokens(doc).first { $0.kind == kind }.map { slice(doc, $0.range) }
}

@Suite struct BlockScanTests {
    @Test func headingLevels() {
        for level in 1...6 {
            let doc = String(repeating: "#", count: level) + " Title"
            let scan = BlockScan.scan(doc as NSString)
            guard case .heading(let l, let marker, let text) = scan.lines[0].kind else {
                Issue.record("not a heading"); return
            }
            #expect(l == level)
            #expect(slice(doc, marker) == String(repeating: "#", count: level) + " ")
            #expect(slice(doc, text) == "Title")
        }
    }

    @Test func sevenHashesIsParagraph() {
        let scan = BlockScan.scan("####### nope" as NSString)
        #expect(scan.lines[0].kind == .paragraph)
    }

    @Test func hashWithoutSpaceIsNotHeading() {
        let scan = BlockScan.scan("#tag not heading" as NSString)
        #expect(scan.lines[0].kind == .paragraph)
    }

    @Test func fencedCodeBlock() {
        let doc = "```swift\nlet x = 1\n```\nafter"
        let scan = BlockScan.scan(doc as NSString)
        #expect(scan.lines[0].kind == .fenceDelimiter(language: "swift"))
        #expect(scan.lines[1].kind == .code(language: "swift"))
        #expect(scan.lines[2].kind == .fenceDelimiter(language: nil))
        #expect(scan.lines[3].kind == .paragraph)
    }

    @Test func unclosedFenceSwallowsRest() {
        let doc = "```\ncode\nstill code"
        let scan = BlockScan.scan(doc as NSString)
        #expect(scan.lines[1].kind == .code(language: nil))
        #expect(scan.lines[2].kind == .code(language: nil))
    }

    @Test func emphasisMarkersInsideFenceStayCode() {
        let doc = "```\n**not bold**\n```"
        let all = tokens(doc)
        #expect(!all.contains { $0.kind == .bold })
        #expect(all.contains { $0.kind == .codeContent(language: nil) })
    }

    @Test func frontmatterLines() {
        let doc = "---\ntitle: X\n---\nbody"
        let scan = BlockScan.scan(doc as NSString)
        #expect(scan.lines[0].kind == .frontmatterDelimiter)
        #expect(scan.lines[1].kind == .frontmatterContent)
        #expect(scan.lines[2].kind == .frontmatterDelimiter)
        #expect(scan.lines[3].kind == .paragraph)
    }

    @Test func hrVersusList() {
        #expect(BlockScan.scan("---" as NSString).lines[0].kind == .horizontalRule)
        #expect(BlockScan.scan("- - -" as NSString).lines[0].kind == .horizontalRule)
        if case .listItem = BlockScan.scan("- item" as NSString).lines[0].kind {
        } else {
            Issue.record("- item should be a list")
        }
    }

    @Test func taskListItems() {
        let doc = "- [x] done\n- [ ] open\n- plain"
        let scan = BlockScan.scan(doc as NSString)
        guard case .listItem(_, _, let t0, _) = scan.lines[0].kind,
              case .listItem(_, _, let t1, _) = scan.lines[1].kind,
              case .listItem(_, _, let t2, _) = scan.lines[2].kind else {
            Issue.record("expected list items"); return
        }
        #expect(t0?.checked == true)
        #expect(t1?.checked == false)
        #expect(t2 == nil)
    }

    @Test func orderedList() {
        let doc = "12. twelve"
        guard case .listItem(let marker, let ordered, _, _) = BlockScan.scan(doc as NSString).lines[0].kind else {
            Issue.record("expected list"); return
        }
        #expect(ordered)
        #expect(slice(doc, marker) == "12. ")
    }

    @Test func blockquote() {
        let doc = "> quoted **bold**"
        let scan = BlockScan.scan(doc as NSString)
        guard case .blockquote(let marker, _) = scan.lines[0].kind else {
            Issue.record("expected quote"); return
        }
        #expect(slice(doc, marker) == "> ")
        #expect(tokens(doc).contains { $0.kind == .bold })
    }

    @Test func tableRows() {
        let doc = "| a | b |\n| --- | :-: |\n| 1 | 2 |"
        let scan = BlockScan.scan(doc as NSString)
        #expect(scan.lines[0].kind == .tableRow)
        #expect(scan.lines[1].kind == .tableDelimiterRow)
        #expect(scan.lines[2].kind == .tableRow)
    }
}

@Suite struct InlineTests {
    @Test func boldItalicNesting() {
        let doc = "**bold *inner* bold**"
        let all = tokens(doc)
        #expect(all.contains { $0.kind == .bold && slice(doc, $0.range) == "bold *inner* bold" })
        #expect(all.contains { $0.kind == .italic && slice(doc, $0.range) == "inner" })
        let markers = all.filter { $0.kind == .emphasisMarker }
        #expect(markers.count == 4)
    }

    @Test func tripleEmphasis() {
        #expect(first("***both***", .boldItalic) == "both")
    }

    @Test func unmatchedEmphasisStaysLiteral() {
        #expect(tokens("just an *asterisk").isEmpty)
        #expect(tokens("2 * 3 = 6").isEmpty)
    }

    @Test func underscoreNeedsWordBoundary() {
        #expect(tokens("snake_case_name").isEmpty)
        #expect(first("_italic_", .italic) == "italic")
    }

    @Test func codeSpanSuppressesEmphasis() {
        let doc = "`a *b* c`"
        let all = tokens(doc)
        #expect(!all.contains { $0.kind == .italic })
        #expect(all.contains { $0.kind == .inlineCode && slice(doc, $0.range) == "a *b* c" })
    }

    @Test func doubleBacktickCode() {
        let doc = "`` a`b ``"
        #expect(first(doc, .inlineCode) == " a`b ")
    }

    @Test func strikethroughAndHighlight() {
        #expect(first("~~gone~~", .strikethrough) == "gone")
        #expect(first("==hot==", .highlight) == "hot")
    }

    @Test func wikiLink() {
        let doc = "see [[My Note]] ok"
        #expect(first(doc, .wikiLinkTarget) == "My Note")
    }

    @Test func wikiLinkWithAlias() {
        let doc = "[[Real Page|shown text]]"
        #expect(first(doc, .wikiLinkTarget) == "Real Page")
        #expect(first(doc, .wikiLinkAlias) == "shown text")
    }

    @Test func markdownLink() {
        let doc = "a [text](https://x.com/p_(y)) b"
        #expect(first(doc, .linkText) == "text")
        #expect(first(doc, .linkURL) == "https://x.com/p_(y)")
    }

    @Test func imageLink() {
        let doc = "![alt](img.png)"
        #expect(first(doc, .linkText) == "alt")
        #expect(first(doc, .linkURL) == "img.png")
        #expect(tokens(doc).contains { $0.kind == .linkBracket && slice(doc, $0.range) == "![" })
    }

    @Test func emphasisInsideLinkText() {
        let doc = "[has *it*](u)"
        #expect(first(doc, .italic) == "it")
    }

    @Test func tags() {
        let doc = "work on #proj/sub and #dev-2 now"
        let names = tokens(doc).filter { $0.kind == .tagName }.map { slice(doc, $0.range) }
        #expect(names == ["proj/sub", "dev-2"])
    }

    @Test func numericOnlyOrMidwordIsNotTag() {
        #expect(tokens("#123").isEmpty)
        #expect(tokens("c#4x").isEmpty)
    }

    @Test func headingTextGetsInlineTokens() {
        let doc = "## With `code` inside"
        #expect(first(doc, .inlineCode) == "code")
    }

    @Test func inlineAndDisplayMath() {
        #expect(first("$e^x$", .mathContent(display: false)) == "e^x")
        #expect(first("$$\\int x$$", .mathContent(display: true)) == "\\int x")
    }

    @Test func currencyIsNotMath() {
        #expect(tokens("$5 and $10").isEmpty)
        #expect(tokens("costs $1,299.99 today").isEmpty)
    }

    @Test func autolink() {
        let doc = "see https://example.com/a. and more"
        #expect(first(doc, .linkURL) == "https://example.com/a")
    }

    @Test func escapedMarkersStayLiteral() {
        #expect(tokens("\\*not italic\\*").isEmpty)
    }
}

@Suite struct IncrementalEquivalenceTests {
    /// Tokens computed for any line subrange must equal the corresponding
    /// slice of a full-document scan.
    @Test func subrangeMatchesFull() {
        let doc = """
        ---
        title: T
        ---
        # Head **b**
        para with [[link]] and #tag
        ```py
        code *x*
        ```
        - [x] done *it*
        > quote `c`
        | a | b |
        """
        let ns = doc as NSString
        let scan = BlockScan.scan(ns)
        let full = MarkdownScan.fullTokens(ns)
        for i in 0..<scan.lines.count {
            let line = scan.lines[i]
            let perLine = MarkdownScan.tokens(ns, scan: scan, lineIndices: i...i)
            let expected = full.filter {
                $0.range.location >= line.range.location
                    && $0.range.location < line.range.location + max(line.range.length, 1)
            }
            #expect(perLine == expected, "line \(i)")
        }
    }

    /// Property test: after random single-char insertions, restyling only the
    /// span (edited lines ∪ signature diff) is sufficient — every line outside
    /// it has identical line-relative tokens before and after the edit.
    @Test func randomEditsCoverAllChangedLines() {
        var doc = """
        # Title
        text **bold** and *it*
        ```
        fence
        ```
        - list [[x]]
        plain #tag
        """
        var rng = SystemRandomNumberGenerator() // structural property; any seed works
        let alphabet = Array("ab*`#-[]$ \n_~=")

        func relativeTokens(_ text: NSString, _ line: BlockScan.Line) -> [Token] {
            MarkdownScan.lineTokens(text, line: line).map {
                Token($0.kind, NSRange(location: $0.range.location - line.range.location,
                                       length: $0.range.length))
            }
        }

        for round in 0..<300 {
            let old = doc as NSString
            let oldScan = BlockScan.scan(old)
            let oldSig = oldScan.structureSignature

            let insertAt = Int.random(in: 0...old.length, using: &rng)
            let char = String(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)])
            let new = old.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: char) as NSString
            doc = new as String

            let newScan = BlockScan.scan(new)
            let span = SignatureDiff.changedLineSpan(old: oldSig, new: newScan.structureSignature)
            let rawEdited = newScan.lineIndices(intersecting: NSRange(location: insertAt, length: 1))
            // Mirror the highlighter: cover one line past the edit (line splits).
            let editedLines = rawEdited.lowerBound...(rawEdited.upperBound + 1)
            let lineDelta = newScan.lines.count - oldScan.lines.count

            for (i, line) in newScan.lines.enumerated() {
                if span.contains(i) || editedLines.contains(i) { continue }
                // Lines before the insertion keep their index; lines after
                // shift by the number of inserted newlines.
                let oldIndex = line.range.location < insertAt ? i : i - lineDelta
                guard oldIndex >= 0, oldIndex < oldScan.lines.count else {
                    Issue.record("round \(round): no aligned old line for \(i)")
                    return
                }
                let newRel = relativeTokens(new, line)
                let oldRel = relativeTokens(old, oldScan.lines[oldIndex])
                #expect(newRel == oldRel, "round \(round), line \(i)")
                if newRel != oldRel { return } // fail fast
            }
        }
    }
}
