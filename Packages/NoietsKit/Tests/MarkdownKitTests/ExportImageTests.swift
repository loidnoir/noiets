import Foundation
import Testing
@testable import MarkdownKit

struct ExportImageTests {
    @Test func markdownAndWikiImagesBecomeImagesIncludingEmptyAlt() {
        let md = "Before 🪷 ![diagram](assets/a.png) after\n\n![](empty-alt.png)\n\n![[Pasted image.png]]\n"
        let html = HTMLExport.html(from: md, title: "T")
        #expect(html.contains("Before 🪷 <img src=\"assets/a.png\" alt=\"diagram\"> after"))
        #expect(html.contains("<img src=\"empty-alt.png\" alt=\"\">"))
        #expect(html.contains("<img src=\"Pasted image.png\" alt=\"Pasted image.png\">"))
        #expect(HTMLExport.images(in: md).map(\.path) == ["assets/a.png", "empty-alt.png", "Pasted image.png"])
    }

    @Test func codeFrontmatterEscapesAndNoteEmbedsDoNotLoadImages() {
        let md = "---\nimage: ![](front.png)\n---\n`![](inline.png)`\n\n```\n![](fenced.png)\n```\n\n\\![[escaped.png]]\n\n![[Note]]\n"
        #expect(HTMLExport.images(in: md).isEmpty)
        #expect(!HTMLExport.html(from: md, title: "T").contains("<img"))
    }

    @Test func attributesAreEscapedAndMissingResourcesRemainVisible() {
        let html = HTMLExport.html(from: #"![a "quote" & <alt>](a&b.png)"#, title: "T")
        #expect(html.contains("src=\"a&amp;b.png\""))
        #expect(html.contains("alt=\"a &quot;quote&quot; &amp; &lt;alt&gt;\""))
        let missing = HTMLExport.html(from: "![](missing.png)", title: "T", imageSource: { _ in nil })
        #expect(missing.contains("Image unavailable: missing.png"))
        #expect(!missing.contains("<img"))
    }

    @Test func formattedAltDoesNotLeakAndAdjacentImagesKeepTheirOrder() {
        let html = HTMLExport.html(from: "**before ![alt](a.png) after** ![](b.png)", title: "T")
        #expect(html.contains("<strong>before <img src=\"a.png\" alt=\"alt\"> after</strong>"))
        #expect(html.contains("<img src=\"b.png\" alt=\"\">"))
        let formatted = HTMLExport.html(from: "![**alt**](a.png)", title: "T")
        #expect(formatted.contains("<img src=\"a.png\" alt=\"**alt**\">"))
        #expect(!formatted.contains("<strong>"))
    }
}
