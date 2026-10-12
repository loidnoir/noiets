import Foundation
import Testing
@testable import IndexKit
import VaultStore

struct SearchNavigationTests {
    @Test func completesKeysAndValuesWithoutReplacingSurroundingQuery() {
        let query = "tag:work layout:mo sort:title"
        let caret = ("tag:work layout:mo" as NSString).length
        let items = ViewQueryCompletion.suggestions(in: query, caret: caret)
        #expect(items.count == 1)
        #expect(items.first?.text == "layout:month")
        let result = (query as NSString).replacingCharacters(in: items[0].range, with: items[0].text)
        #expect(result == "tag:work layout:month sort:title")
        #expect(ViewQuery.parse(result).layout == .month)
        #expect(ViewQueryCompletion.suggestions(in: "lay", caret: 3).first?.text == "layout:")
    }

    @Test func replacesWholeTokenWhenCaretIsInTheMiddleAndUsesUTF16() {
        let query = "🪷 layout:montypo tag:work"
        let caret = ("🪷 layout:mo" as NSString).length
        let item = ViewQueryCompletion.suggestions(in: query, caret: caret)[0]
        #expect((query as NSString).replacingCharacters(in: item.range, with: item.text) == "🪷 layout:month tag:work")
        #expect(ViewQueryCompletion.suggestions(in: "🪷", caret: 2).isEmpty)
        #expect(ViewQueryCompletion.suggestions(in: "", caret: -1).isEmpty)
        #expect(ViewQueryCompletion.suggestions(in: "lay", caret: 4).isEmpty)
    }

    @Test func supportsSortDatesLimitsAndProjectValues() {
        #expect(ViewQueryCompletion.suggestions(in: "sort:-", caret: 6).map(\.text).contains("sort:-title"))
        #expect(ViewQueryCompletion.suggestions(in: "modified:<", caret: 10).map(\.text).contains("modified:<7d"))
        #expect(ViewQueryCompletion.suggestions(in: "limit:5", caret: 7).map(\.text) == ["limit:50", "limit:500"])
        let tags = ViewQueryCompletion.suggestions(in: "tag:w", caret: 5, tags: ["work", "writing", "other"])
        #expect(tags.map(\.text) == ["tag:work", "tag:writing"])
        let folders = ViewQueryCompletion.suggestions(in: "folder:", caret: 7, folders: ["Work", "Work/Notes", "Two words"])
        #expect(folders.map(\.text) == ["folder:Work", "folder:Work/Notes"])
        #expect(ViewQueryCompletion.suggestions(in: "status:", caret: 7, properties: ["status": ["done"]]).map(\.text) == ["status:*", "status:done"])
        #expect(ViewQueryCompletion.suggestions(in: "layout:month", caret: 12).isEmpty)
    }

    @Test func savedViewsLeadExactNameNotesAndDoNotReplaceThem() throws {
        let index = try NoteIndex.temporary(vault: Vault(rootURL: URL(fileURLWithPath: "/tmp/search-navigation")))
        let note = NoteExtractor.extract(markdown: "# Notes\ntext", fallbackTitle: "Notes")
        try index.upsert(relPath: "Notes.md", extracted: note, mtime: 1000, size: 10, created: 900)
        let view = SavedView(name: "Notes", query: "layout:month")
        let result = try index.quickOpenDestinations("notes", views: [view, SavedView(name: "Other", query: "")])
        #expect(result.count == 2)
        #expect(result[0] == .view(view))
        if case .note(let row) = result[1] { #expect(row.relPath == "Notes.md") }
        else { Issue.record("Document missing after matching view") }
        #expect(try index.quickOpenDestinations("notes", views: [view], limit: 1) == [.view(view)])
        #expect(try index.quickOpenDestinations("notes", views: [view], limit: 0).isEmpty)
        #expect(try index.quickOpen("notes").count == 1) // wiki completion is still note-only
    }

    @Test func viewRankingAndPropertyCatalogAreStable() throws {
        let index = try NoteIndex.temporary(vault: Vault(rootURL: URL(fileURLWithPath: "/tmp/search-navigation")))
        let note = NoteExtractor.extract(markdown: "---\nstatus: done\n---\n# Test", fallbackTitle: "Test")
        try index.upsert(relPath: "Test.md", extracted: note, mtime: 1000, size: 10, created: 900)
        #expect(try index.queryCompletionProperties()["status"] == ["done"])
        let views = [SavedView(name: "Old Notes", query: ""), SavedView(name: "Notes archive", query: ""), SavedView(name: "Notes", query: "")]
        #expect(try index.quickOpenDestinations("notes", views: views).prefix(3) == [.view(views[2]), .view(views[1]), .view(views[0])])
        #expect(try index.quickOpenDestinations("", views: views).prefix(3) == views.map { .view($0) }[...])
    }
}
