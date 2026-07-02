import Foundation
import Testing
@testable import MarkdownKit

@Suite struct FrontmatterTests {
    @Test func parsesBasicFrontmatter() {
        let doc = "---\ntitle: X\ntags: [a, b]\n---\n# Hi\n"
        let fm = Frontmatter.parse(in: doc)
        #expect(fm != nil)
        #expect(fm?.content == "title: X\ntags: [a, b]\n")
        let ns = doc as NSString
        #expect(ns.substring(with: fm!.range) == "---\ntitle: X\ntags: [a, b]\n---\n")
    }

    @Test func closingDotsFence() {
        let doc = "---\na: 1\n...\nbody"
        #expect(Frontmatter.parse(in: doc)?.content == "a: 1\n")
    }

    @Test func requiresDocumentStart() {
        #expect(Frontmatter.parse(in: "\n---\na: 1\n---\n") == nil)
        #expect(Frontmatter.parse(in: "# Hi\n---\n") == nil)
    }

    @Test func unclosedIsNotFrontmatter() {
        #expect(Frontmatter.parse(in: "---\ntitle: X\n") == nil)
    }

    @Test func emptyDocument() {
        #expect(Frontmatter.parse(in: "") == nil)
        #expect(Frontmatter.parse(in: "---") == nil)
    }
}
