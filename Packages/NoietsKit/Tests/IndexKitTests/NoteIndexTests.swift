import Foundation
import Testing
@testable import IndexKit
import VaultStore

private func makeIndex() throws -> NoteIndex {
    try NoteIndex.temporary(vault: Vault(rootURL: URL(fileURLWithPath: "/tmp/fake-vault")))
}

private func put(
    _ index: NoteIndex, _ relPath: String, _ markdown: String,
    mtime: Double = 1000, size: Int = 10
) throws {
    let fallback = (relPath as NSString).lastPathComponent
        .replacingOccurrences(of: ".md", with: "")
    let extracted = NoteExtractor.extract(markdown: markdown, fallbackTitle: fallback)
    try index.upsert(relPath: relPath, extracted: extracted, mtime: mtime, size: size, created: 900)
    try index.resolveLinks() // batch-level in production (Reindexer)
}

@Suite struct ExtractorTests {
    @Test func titleFromH1ElseFilename() {
        let a = NoteExtractor.extract(markdown: "# Real Title\nbody", fallbackTitle: "file")
        #expect(a.title == "Real Title")
        let b = NoteExtractor.extract(markdown: "no heading here", fallbackTitle: "file")
        #expect(b.title == "file")
    }

    @Test func tagsFromBodyAndFrontmatter() {
        let doc = """
        ---
        tags: [alpha, Beta]
        ---
        Work on #gamma/delta now
        """
        let e = NoteExtractor.extract(markdown: doc, fallbackTitle: "f")
        #expect(e.tags == ["alpha", "beta", "gamma/delta"])
    }

    @Test func linksNormalizeHeadingAndAlias() {
        let doc = "See [[Target Note#Section]] and [[Other|shown]] plus [[Plain]]"
        let e = NoteExtractor.extract(markdown: doc, fallbackTitle: "f")
        #expect(e.links.map(\.targetTitle) == ["Target Note", "Other", "Plain"])
    }
}

@Suite struct NoteIndexTests {
    @Test func ftsSearchFindsBodyAndRanksTitle() throws {
        let index = try makeIndex()
        try put(index, "a.md", "# Rocket Science\nnotes about various things")
        try put(index, "b.md", "# Other\nthis mentions rocket once")
        let hits = try index.searchNotes("rocket")
        #expect(hits.count == 2)
        #expect(hits.first?.title == "Rocket Science") // title match ranks first
        #expect(hits.last?.snippet.contains("rocket") == true)
    }

    @Test func prefixSearchWorks() throws {
        let index = try makeIndex()
        try put(index, "a.md", "# Notes\ntypography matters")
        #expect(try index.searchNotes("typog").count == 1)
    }

    @Test func quickOpenPrefixBeatsContains() throws {
        let index = try makeIndex()
        try put(index, "planning.md", "# Planning", mtime: 1)
        try put(index, "plan.md", "# Plan", mtime: 2)
        try put(index, "workplan.md", "# Workplan", mtime: 3)
        let rows = try index.quickOpen("plan")
        #expect(rows.count == 3)
        // Prefix matches (plan, planning) come before contains (workplan).
        #expect(rows.last?.stem == "workplan")
    }

    @Test func backlinksResolveByStemAndTitle() throws {
        let index = try makeIndex()
        try put(index, "target.md", "# The Target\ncontent")
        try put(index, "a.md", "links to [[target]]")          // by stem
        try put(index, "b.md", "links to [[The Target]] too")  // by title
        let backlinks = try index.backlinks(to: "target.md")
        #expect(backlinks.count == 2)
        #expect(Set(backlinks.map(\.sourceRelPath)) == ["a.md", "b.md"])
    }

    @Test func renameReResolvesLinks() throws {
        let index = try makeIndex()
        try put(index, "a.md", "see [[fresh]]")
        #expect(try index.backlinks(to: "old.md").isEmpty)
        // A new note appears whose stem matches the dangling link.
        try put(index, "fresh.md", "# Fresh")
        let backlinks = try index.backlinks(to: "fresh.md")
        #expect(backlinks.map(\.sourceRelPath) == ["a.md"])
    }

    @Test func deleteRemovesRowAndUnresolvesInbound() throws {
        let index = try makeIndex()
        try put(index, "t.md", "# T")
        try put(index, "src.md", "link [[t]]")
        #expect(try index.backlinks(to: "t.md").count == 1)
        try index.deleteNote(relPath: "t.md")
        #expect(try index.backlinks(to: "t.md").isEmpty)
        #expect(try index.searchNotes("T").allSatisfy { $0.relPath != "t.md" })
        // Recreating the note re-resolves the dangling edge.
        try put(index, "t.md", "# T")
        #expect(try index.backlinks(to: "t.md").count == 1)
    }

    @Test func tagsQueryable() throws {
        let index = try makeIndex()
        try put(index, "a.md", "#swift and #vim")
        try put(index, "b.md", "more #swift")
        let tags = try index.allTags()
        #expect(tags.first?.name == "swift")
        #expect(tags.first?.count == 2)
        #expect(try index.notes(withTag: "vim").map(\.relPath) == ["a.md"])
    }

    @Test func upsertIsIdempotentAndUpdates() throws {
        let index = try makeIndex()
        try put(index, "a.md", "# One\nfirst", mtime: 1)
        try put(index, "a.md", "# Two\nsecond", mtime: 2)
        let all = try index.allNotes()
        #expect(all.count == 1)
        #expect(all.first?.title == "Two")
        #expect(try index.searchNotes("first").isEmpty)
        #expect(try index.searchNotes("second").count == 1)
    }

    @Test func linkTargetLookup() throws {
        let index = try makeIndex()
        try put(index, "Deep/My Note.md", "# Custom Title")
        #expect(try index.note(matchingLinkTarget: "my note")?.relPath == "Deep/My Note.md")
        #expect(try index.note(matchingLinkTarget: "Custom Title")?.relPath == "Deep/My Note.md")
        #expect(try index.note(matchingLinkTarget: "nope") == nil)
    }
}
