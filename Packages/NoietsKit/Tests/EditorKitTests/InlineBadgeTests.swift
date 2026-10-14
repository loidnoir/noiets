import AppKit
import Testing
import RenderKit
@testable import EditorKit

@MainActor
@Suite struct InlineBadgeTests {
    private func editor(_ text: String, width: CGFloat = 800) -> (NSWindow, MarkdownEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        let editor = MarkdownEditorView()
        editor.tagColourProvider = { _ in TagPalette.color(at: 0) }
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        editor.load(text: text)
        editor.highlighter.restyleAll(editor.textView.textStorage!)
        editor.textView.textLayoutManager!.ensureLayout(for: editor.textView.textLayoutManager!.documentRange)
        return (window, editor)
    }

    private func fragment(at index: Int, in editor: MarkdownEditorView) throws -> NSTextLayoutFragment {
        let content = try #require(editor.textView.textContentStorage)
        let location = try #require(content.location(content.documentRange.location, offsetBy: index))
        return try #require(editor.textView.textLayoutManager?.textLayoutFragment(for: location))
    }

    @Test func renderedTagsUseNormalTextAndClickableSharedIdentityWithoutChangingSource() throws {
        let source = "Body\n\n#reading #日本語\n\nAfter\n"
        let (window, editor) = editor(source)
        defer { window.contentView = nil }
        let range = (source as NSString).range(of: "#reading")
        let storage = try #require(editor.textView.textStorage)
        #expect(storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == editor.theme.textColor)
        #expect(storage.attribute(.foregroundColor, at: range.location + 1, effectiveRange: nil) as? NSColor == editor.theme.textColor)
        #expect(storage.attribute(.noietsTagColour, at: range.location, effectiveRange: nil) as? NSColor == TagPalette.color(at: 0))
        #expect((storage.attribute(.link, at: range.location, effectiveRange: nil) as? String)?.hasPrefix("noiets://tag/reading") == true)
        #expect(editor.textView.linkTextAttributes?[.foregroundColor] == nil)
        let overlay = try #require(try fragment(at: range.location, in: editor) as? OverlayLineFragment)
        let tags = overlay.spans.filter { if case .tag = $0.kind { return true }; return false }
        #expect(tags.count == 2)
        #expect(editor.string == source)
    }

    @Test func activeSourceLineRevertsBadgesAndLockedNotesKeepThem() throws {
        let source = "Body\n\n#reading\n"
        let (window, editor) = editor(source)
        defer { window.contentView = nil }
        let range = (source as NSString).range(of: "#reading")
        editor.textView.setSelectedRange(NSRange(location: range.location + 3, length: 0))
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        editor.textView.textLayoutManager!.ensureLayout(for: editor.textView.textLayoutManager!.documentRange)
        #expect(editor.textView.textStorage!.attribute(.noietsTagColour, at: range.location, effectiveRange: nil) == nil)
        #expect(!(try fragment(at: range.location, in: editor) is OverlayLineFragment))
        editor.setLocked(true)
        editor.textView.textLayoutManager!.ensureLayout(for: editor.textView.textLayoutManager!.documentRange)
        #expect(try fragment(at: range.location, in: editor) is OverlayLineFragment)
        #expect(editor.string == source)
    }

    @Test func codeSidePaddingIsTightWhileVerticalGeometryStaysUnchanged() throws {
        let source = "Body\n\nBefore `code` after\n"
        let (window, editor) = editor(source)
        defer { window.contentView = nil }
        let range = (source as NSString).range(of: "code")
        let fragment = try #require(try fragment(at: range.location, in: editor) as? OverlayLineFragment)
        let span = try #require(fragment.spans.first { if case .chip = $0.kind { return true }; return false })
        guard case .chip(let relative) = span.kind else { return }
        let rect = try #require(fragment.chipRects(for: relative, at: .zero).first)
        let line = try #require(fragment.textLineFragments.first { NSIntersectionRange(relative, $0.characterRange).length > 0 })
        let start = line.locationForCharacter(at: relative.location).x
        let end = line.locationForCharacter(at: NSMaxRange(relative)).x
        #expect(abs(rect.width - abs(end - start) - 4) < 0.01)
        #expect(abs(rect.height - (line.typographicBounds.height - 3)) < 0.01)
        #expect(OverlayLineFragment.chipPadding == 2)
        #expect(InlineChipStyle.cornerRadius == 4)
    }

    @Test func tagsInHeadingsQuotesListsAndWrappedTextGetBadgesButCodeDoesNot() throws {
        let source = "Body\n\n## Heading #reading\n\n> Quote #reading\n\n- List #reading\n\n#" + String(repeating: "日本語", count: 60) + "\n\n`#not_a_tag`\n"
        let (window, editor) = editor(source, width: 420)
        defer { window.contentView = nil }
        let text = source as NSString
        for needle in ["## Heading", "> Quote", "- List", "#日本語"] {
            let overlay = try #require(try fragment(at: text.range(of: needle).location, in: editor) as? OverlayLineFragment)
            #expect(overlay.spans.contains { if case .tag = $0.kind { return true }; return false })
        }
        let wrapped = try #require(try fragment(at: text.range(of: "#日本語").location, in: editor) as? OverlayLineFragment)
        let span = try #require(wrapped.spans.first { if case .tag = $0.kind { return true }; return false })
        if case .tag(let range, _) = span.kind { #expect(wrapped.chipRects(for: range, at: .zero).count > 1) }
        let code = try #require(try fragment(at: text.range(of: "#not_a_tag").location, in: editor) as? OverlayLineFragment)
        #expect(!code.spans.contains { if case .tag = $0.kind { return true }; return false })
    }

    @Test func completionUsesBadgesForTagsAndKeepsOtherSuggestionsPlain() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        let popup = WikiLinkAutocomplete()
        defer { popup.hide() }
        popup.tagColourProvider = { _ in TagPalette.color(at: 7) }
        popup.show(suggestions: ["#reading", "Plain note", "tag:coding"], at: NSRect(x: 0, y: 300, width: 100, height: 20), parent: window) { _ in }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for child in view.subviews { if let match = find(type, in: child) { return match } }
            return nil
        }
        let content = try #require(popup.contentView)
        let table = try #require(find(NSTableView.self, in: content))
        for row in [0, 2] {
            let cell = try #require(popup.tableView(table, viewFor: table.tableColumns[0], row: row))
            let badge = try #require(find(TagBadgeView.self, in: cell))
            #expect(!badge.isHidden)
            #expect(badge.colour == TagPalette.color(at: 7))
        }
        let plain = try #require(popup.tableView(table, viewFor: table.tableColumns[0], row: 1))
        #expect(find(TagBadgeView.self, in: plain)?.isHidden == true)
        popup.hide()
        #expect(popup.tableView(table, viewFor: table.tableColumns[0], row: 0) == nil)
    }

    @Test func badgeViewHasNormalFontAndCompactIntrinsicPadding() {
        let badge = TagBadgeView()
        badge.name = "#reading"
        let text = (badge.name as NSString).size(withAttributes: [.font: badge.font])
        #expect(badge.intrinsicContentSize.width - ceil(text.width) == 6) // 2pt each side + outline clearance
        #expect(badge.intrinsicContentSize.height - ceil(text.height) == 5)
        #expect(badge.font.fontDescriptor.symbolicTraits.contains(.bold) == false)
        #expect(InlineChipStyle.tagBackground(.red).alphaComponent == 0.14)
    }

    @Test func assignmentMapIsSharedStableAndCompatibleWithExistingWidgetColours() throws {
        let suite = "Noiets.TagBadgeTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["reading": 7, "coding": 0], forKey: "Noiets.TagColours.vault")
        let store = TagColourStore(namespace: "vault", defaults: defaults)
        store.prepare(["exercise", "japanese", "reading", "coding"])
        #expect(store.colour(for: "READING") == TagPalette.color(at: 7))
        #expect(store.colour(for: "coding") == TagPalette.color(at: 0))
        let restored = TagColourStore(namespace: "vault", defaults: defaults)
        #expect(restored.colour(for: "japanese") == store.colour(for: "japanese"))
        #expect(Set(["exercise", "japanese", "reading", "coding"].map { store.colour(for: $0) }).count == 4)
        let independent = TagColourStore(namespace: "other-vault", defaults: defaults)
        #expect(independent.colour(for: "reading") == TagPalette.color(at: 0))
    }
}
