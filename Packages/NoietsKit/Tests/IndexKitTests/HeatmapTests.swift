import Foundation
import GRDB
import Testing
import VaultStore
@testable import IndexKit

@Suite struct HeatmapTests {
    @Test func widgetGrammarAndHighlighting() {
        #expect(ViewQuery.parse("widget:heatmap").heatmap == .init())
        #expect(ViewQuery.parse("widget:HEATMAP?TAGS").heatmap == .init(tags: .discovered))
        let query = ViewQuery.parse("folder:Habits layout:month widget:heatmap?tags=Reading,japanese,reading")
        #expect(query.heatmap == .init(tags: .specified(["reading", "japanese"])))
        #expect(query.props.isEmpty)
        #expect(query.textTerms.isEmpty)
        #expect(query.layout == .month)
        for token in ["widget:bogus", "widget:heatmap?unknown", "widget:heatmap?tags=", "widget:heatmap?tags=a,", "widget:heatmap?tags=a,,b", "widget:heatmap?tags=a?b"] {
            #expect(ViewQuery.parse(token) == ViewQuery())
            #expect(ViewQuery.filterTokenRanges(token).isEmpty)
        }
        #expect(ViewQuery.parse("created:>2026-02-30") == ViewQuery())
        let text = "widget:heatmap?tags=a,b layout:month words"
        #expect(ViewQuery.filterTokenRanges(text).map { (text as NSString).substring(with: $0) } == ["widget:heatmap?tags=a,b", "layout:month"])
    }

    @Test func widgetSuggestionsPreserveCommaListAndOtherTokens() {
        #expect(ViewQueryCompletion.suggestions(in: "wid", caret: 3).map(\.text) == ["widget:"])
        #expect(ViewQueryCompletion.suggestions(in: "widget:h", caret: 8).map(\.text).contains("widget:heatmap?tags"))
        let text = "folder:Habits widget:heatmap?tags=reading,ja sort:created"
        let caret = (text as NSString).range(of: " sort:").location
        let suggestions = ViewQueryCompletion.suggestions(in: text, caret: caret, tags: ["reading", "japanese", "coding"])
        #expect(suggestions.map(\.text) == ["widget:heatmap?tags=reading,japanese"])
        #expect((text as NSString).replacingCharacters(in: suggestions[0].range, with: suggestions[0].text) == "folder:Habits widget:heatmap?tags=reading,japanese sort:created")
    }

    @Test func uniqueNotesAndTagSwitching() throws {
        let now = try #require(NoteDate.parse("2026-10-14"))
        let old = try #require(NoteDate.parse("2024-01-01"))
        let hits: [NoteIndex.SearchHit] = [
            .init(id: 1, relPath: "a.md", title: "A", snippet: "", tags: ["reading", "japanese"], created: now.timeIntervalSince1970),
            .init(id: 2, relPath: "b.md", title: "B", snippet: "", tags: ["reading"], created: now.timeIntervalSince1970),
            .init(id: 3, relPath: "c.md", title: "C", snippet: "", tags: ["coding"], created: old.timeIntervalSince1970)
        ]
        let all = HeatmapData(hits: hits + [hits[0]], now: now)
        #expect(all.days.last?.count == 2)
        #expect(all.days.reduce(0) { $0 + $1.count } == 2)
        #expect(HeatmapData(hits: hits, tag: "japanese", now: now).days.last?.count == 1)
        #expect(HeatmapData(hits: hits, tag: "missing", now: now).days.allSatisfy { $0.count == 0 })
        #expect(HeatmapData.filtered(hits, tag: "reading", day: now).map(\.id) == [1, 2])
        #expect(HeatmapData.filtered(hits, tag: "reading", day: old).isEmpty)
        #expect(HeatmapData.tagChoices(for: .init(tags: .discovered), hits: hits) == ["coding", "japanese", "reading"])
        #expect(HeatmapData.tagChoices(for: .init(tags: .specified(["missing", "reading"])), hits: hits) == ["missing", "reading"])
        #expect(HeatmapData.tagChoices(for: .init(), hits: hits).isEmpty)
    }

    @Test func calendarDaysAcrossDSTAndFutureNotes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        let data = HeatmapData(hits: [.init(id: 1, relPath: "future.md", title: "F", snippet: "", created: now.addingTimeInterval(86400 * 2).timeIntervalSince1970)], now: now, calendar: calendar)
        #expect(data.days.count == 366)
        #expect(data.days.allSatisfy { $0.count == 0 })
        for pair in zip(data.days, data.days.dropFirst()) {
            #expect(calendar.dateComponents([.day], from: pair.0.date, to: pair.1.date).day == 1)
        }
    }
}

@Suite struct EffectiveCreationDateTests {
    private func index() throws -> NoteIndex {
        try NoteIndex.temporary(vault: Vault(rootURL: URL(fileURLWithPath: "/tmp/noiets-date-tests")))
    }
    private func put(_ index: NoteIndex, _ path: String, _ markdown: String, created: Double = 100, modified: Double = 200) throws {
        try index.upsert(relPath: path, extracted: NoteExtractor.extract(markdown: markdown, fallbackTitle: path),
                         mtime: modified, size: markdown.utf8.count, created: created)
    }

    @Test func strictDatesAndTimestamps() throws {
        #expect(NoteDate.parse("2026-10-14") != nil)
        #expect(NoteDate.parse("2024-02-29") != nil)
        #expect(NoteDate.parse("2026-10-14T23:30:00Z") != nil)
        #expect(NoteDate.parse("2026-10-14T23:30:00.123+03:00") != nil)
        for value in ["2026-02-29", "2026-13-01", "2026-10-32", "2026-1-1", "today", "", "2026-10-14garbage", "2026-10-14T23:30:00", "2026-02-30T12:00:00Z"] {
            #expect(NoteDate.parse(value) == nil)
        }
        #expect(NoteDate.override(in: ["created_at": ["2026-10-14", "2026-10-15"]]) == nil)
    }

    @Test func overrideSortFilterAndPhysicalMetadataStaySeparate() throws {
        let index = try index()
        let epoch = try #require(NoteDate.parse("2026-10-14")).timeIntervalSince1970
        try put(index, "override.md", "---\ncreated_at: '2026-10-14'\n---\n# Override", created: 10, modified: 100)
        try put(index, "fallback.md", "# Fallback", created: 20, modified: 300)
        let byCreated = try index.notes(matching: ViewQuery.parse("sort:created"))
        #expect(byCreated.map(\.relPath) == ["override.md", "fallback.md"])
        #expect(byCreated[0].created == epoch)
        #expect(byCreated[0].mtime == 100)
        #expect(try index.notes(matching: ViewQuery.parse("created:>2026-01-01")).map(\.relPath) == ["override.md"])
        #expect(try index.notes(matching: ViewQuery.parse("sort:modified")).map(\.relPath) == ["fallback.md", "override.md"])
        let physical = try #require(index.allNotes().first { $0.relPath == "override.md" })
        #expect(physical.created == 10)
        #expect(physical.effectiveCreated == epoch)
        #expect(try index.notes(matching: ViewQuery.parse("created_at:2026-10-14")).count == 1)
    }

    @Test func widgetPreservesFilterMembershipAndQueryLimit() throws {
        let index = try index()
        try put(index, "Habits/a.md", "# A\n#reading")
        try put(index, "Habits/b.md", "# B\n#coding")
        try put(index, "Other/c.md", "# C\n#reading")
        let plain = try index.notes(matching: ViewQuery.parse("folder:Habits limit:1"))
        let widget = try index.notes(matching: ViewQuery.parse("folder:Habits limit:1 widget:heatmap?tags=reading,coding"))
        #expect(widget == plain)
        #expect(widget.count == 1)
    }

    @Test func editsRemovalAndInvalidValuesFallBackWithoutMovingPhysicalCreation() throws {
        let index = try index()
        try put(index, "a.md", "---\ncreated_at: 2026-10-14\n---\nbody", created: 123)
        try put(index, "a.md", "---\ncreated_at: 2026-10-13\n---\nedited", created: 999, modified: 555)
        #expect(try index.notes(matching: ViewQuery()).first?.created == NoteDate.parse("2026-10-13")?.timeIntervalSince1970)
        for markdown in ["---\ncreated_at: invalid\n---\nbody", "---\ncreated_at: [2026-10-13, 2026-10-14]\n---\nbody", "body"] {
            try put(index, "a.md", markdown, created: 999, modified: 666)
            #expect(try index.notes(matching: ViewQuery()).first?.created == 123)
            #expect(try index.allNotes().first?.created == 123)
        }
    }

    @Test func v5BackfillsExistingPropertiesWithoutWipingNotesOrUserData() throws {
        let index = try index()
        try put(index, "a.md", "---\ncreated_at: 2026-10-14\n---\n# A\n#reading [[B]]")
        try put(index, "b.md", "---\ncreated_at: invalid\n---\n# B")
        try index.setLocked(relPath: "a.md", true)
        try index.setTrashOrigin(name: "gone.md", originFolder: "Habits")
        // Emulate the schema before v5, including its indexed frontmatter.
        try index.pool.write { db in
            try db.execute(sql: "ALTER TABLE note DROP COLUMN frontmatterCreated")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v5'")
        }
        let reopened = try NoteIndex(vault: index.vault, databaseURL: URL(fileURLWithPath: index.pool.path))
        #expect(try reopened.allNotes().count == 2)
        #expect(try reopened.lockedRelPaths() == ["a.md"])
        #expect(try reopened.trashOrigin(name: "gone.md") == "Habits")
        #expect(try reopened.notes(matching: ViewQuery.parse("tag:reading")).first?.created == NoteDate.parse("2026-10-14")?.timeIntervalSince1970)
        #expect(try reopened.notes(matching: ViewQuery.parse("title:B")).first?.created == 100)
        #expect(try reopened.searchNotes("body").isEmpty)
        #expect(try reopened.searchNotes("reading").count == 1)
    }
}
