import Foundation
import Testing
@testable import MarkdownKit

struct QuoteContinuationTests {
    @Test func plainLinesStayQuotedUntilBlankWithoutInventingMarkers() {
        let text = "> First **quote**\nContinued *text*\nAnother continuation\n\nNormal text\n" as NSString
        let scan = BlockScan.scan(text)
        for index in 0...2 {
            guard case .blockquote(let marker, let start) = scan.lines[index].kind else {
                Issue.record("Expected quote at line \(index)"); continue
            }
            if index > 0 {
                #expect(marker.length == 0)
                #expect(start == scan.lines[index].contentRange.location)
                #expect(!MarkdownScan.lineTokens(text, line: scan.lines[index]).contains { $0.kind == .blockquoteMarker })
            }
        }
        #expect(scan.lines[3].kind == .blank)
        #expect(scan.lines[4].kind == .paragraph)
        let html = HTMLExport.html(from: text as String, title: "Quote")
        #expect(html.contains("<p>\nFirst <strong>quote</strong>\nContinued <em>text</em>\nAnother continuation\n</p>\n</blockquote>"))
        #expect(html.contains("</blockquote>\n<p>Normal text</p>"))
    }

    @Test(arguments: ["# Heading", "- List item", "1. Ordered item", "---", "```swift", "$$"])
    func blockSyntaxInterruptsLazyQuotes(block: String) {
        let scan = BlockScan.scan("> Quote\n\(block)\nFollowing\n" as NSString)
        if case .blockquote = scan.lines[1].kind { Issue.record("Block must interrupt lazy quote") }
        if case .blockquote = scan.lines[2].kind { Issue.record("Quote must not leak after interruption") }
    }

    @Test(arguments: [">\nOutside", "> # Heading\nOutside", "> ```\nOutside", "> Quote\n> \nOutside"])
    func nonParagraphQuoteDoesNotPermitLazyContinuation(text: String) {
        #expect(BlockScan.scan(text as NSString).lines.last!.kind == .paragraph)
    }

    @Test func explicitMarkersRestartQuotesAndCRLFIsHandled() {
        let scan = BlockScan.scan("> First\r\nLazy\r\n\r\nNormal\r\n> Second\r\nAgain" as NSString)
        #expect(scan.lines[3].kind == .paragraph)
        for index in [0, 1, 4, 5] {
            if case .blockquote = scan.lines[index].kind {} else { Issue.record("Expected quote") }
        }
    }
}
