import Foundation
import Testing
@testable import MarkdownKit

@Suite struct HTMLExportTests {
    private func body(_ md: String) -> String {
        let html = HTMLExport.html(from: md, title: "T")
        let start = html.range(of: "<body>")!.upperBound
        let end = html.range(of: "</body>")!.lowerBound
        return String(html[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func headingAndInline() {
        let out = body("# Hi **bold** *it*\n")
        #expect(out == "<h1>Hi <strong>bold</strong> <em>it</em></h1>")
    }

    @Test func markersNeverLeak() {
        let out = body("**bold** and `code` and [[Wiki]]")
        #expect(!out.contains("**"))
        #expect(!out.contains("`"))
        #expect(!out.contains("[["))
    }

    @Test func codeBlockEscapes() {
        let out = body("```swift\nlet a = 1 < 2\n```\n")
        #expect(out.contains("<pre><code class=\"language-swift\">"))
        #expect(out.contains("let a = 1 &lt; 2"))
        #expect(out.contains("</code></pre>"))
    }

    @Test func mermaidBlockBecomesDiagramDiv() {
        let out = body("```mermaid\ngraph TD\n  A --> B\n```\n")
        #expect(out.contains("<div class=\"mermaid\">"))
        #expect(out.contains("A --&gt; B"))
        #expect(out.contains("</div>"))
        #expect(out.contains("mermaid.initialize"))
        #expect(!out.contains("<pre>"))
    }

    @Test func nonMermaidExportSkipsMermaidScript() {
        let out = body("```swift\nlet a = 1\n```\n")
        #expect(!out.contains("mermaid"))
    }

    @Test func listsAndTasks() {
        let out = body("- one\n- [x] done\n\n1. first\n")
        #expect(out.contains("<ul>"))
        #expect(out.contains("<li>one</li>"))
        #expect(out.contains("checked"))
        #expect(out.contains("<ol>"))
        #expect(out.contains("<li>first</li>"))
    }

    @Test func linksAndTable() {
        let out = body("[text](https://x.y)\n\n| a | b |\n| - | - |\n| 1 | 2 |\n")
        #expect(out.contains("<a href=\"https://x.y\">text</a>"))
        #expect(out.contains("<th>a</th><th>b</th>"))
        #expect(out.contains("<td>1</td><td>2</td>"))
    }

    @Test func frontmatterOmitted() {
        let out = body("---\ntitle: X\n---\nbody text\n")
        #expect(!out.contains("title: X"))
        #expect(out.contains("<p>body text</p>"))
    }

    @Test func blockquoteAndHR() {
        let out = body("> hello\n\n---\n").replacingOccurrences(of: "\n", with: "")
        #expect(out.contains("<blockquote><p>hello</p></blockquote>"))
        #expect(out.contains("<hr>"))
    }
}
