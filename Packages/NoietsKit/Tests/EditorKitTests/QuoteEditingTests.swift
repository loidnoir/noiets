import AppKit
import Testing
@testable import EditorKit

@MainActor
struct QuoteEditingTests {
    private let markdown = "Body\n> First quote that wraps onto several lines when the editor is narrow.\n> Second quote\n> Third quote\n\nAfter\n"

    private func makeEditor() -> MarkdownEditorView {
        let editor = MarkdownEditorView()
        editor.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        editor.layoutSubtreeIfNeeded()
        editor.load(text: markdown)
        editor.highlighter.restyleAll(editor.textView.textStorage!)
        editor.textView.textLayoutManager!.ensureLayout(for: editor.textView.textLayoutManager!.documentRange)
        return editor
    }

    private func fragment(at word: String, in editor: MarkdownEditorView) -> NSTextLayoutFragment {
        let storage = editor.textView.textContentStorage!
        let index = (editor.string as NSString).range(of: word).location
        let location = storage.location(storage.documentRange.location, offsetBy: index)!
        let manager = editor.textView.textLayoutManager!
        manager.ensureLayout(for: manager.documentRange)
        return manager.textLayoutFragment(for: location)!
    }

    private func select(_ word: String, in editor: MarkdownEditorView) {
        let index = (editor.string as NSString).range(of: word).location
        editor.textView.setSelectedRange(NSRange(location: index, length: 0))
        // Also exercise the delegate in windowless tests where AppKit may
        // defer the selection notification until the view is attached.
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
    }

    @Test func activeQuotesKeepGrayLibronButNoBar() {
        let editor = makeEditor()
        #expect(fragment(at: "First", in: editor) is QuoteBarFragment)
        select("First", in: editor)
        #expect(!(fragment(at: "First", in: editor) is QuoteBarFragment))
        #expect(fragment(at: "Second", in: editor) is QuoteBarFragment)

        let storage = editor.textView.textStorage!
        let text = storage.string as NSString
        let index = text.range(of: "First").location
        let color = storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as! NSColor
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as! NSFont
        #expect(color.isEqual(editor.theme.mutedColor))
        #expect(font.fontName == "Libron-Regular")
        let marker = text.range(of: "> First").location
        #expect(storage.attribute(.noietsHidden, at: marker, effectiveRange: nil) == nil)
        #expect(editor.string == markdown)

        select("After", in: editor)
        #expect(fragment(at: "First", in: editor) is QuoteBarFragment)
        #expect(storage.attribute(.noietsHidden, at: marker, effectiveRange: nil) != nil)
        #expect(editor.string == markdown)
    }

    @Test func adjacentBarsCapAtTheEditingParagraph() {
        let editor = makeEditor()
        let joined = fragment(at: "Third", in: editor) as! QuoteBarFragment
        #expect(joined.joinsPrevious)
        #expect(joined.barRect.minY == -1)
        select("Second", in: editor)
        #expect(!(fragment(at: "Second", in: editor) is QuoteBarFragment))
        let first = fragment(at: "First", in: editor) as! QuoteBarFragment
        let third = fragment(at: "Third", in: editor) as! QuoteBarFragment
        #expect(!first.joinsNext)
        #expect(!third.joinsPrevious)
        #expect(third.barRect.minY > 0)
    }

    @Test func selectionAndTypingDoNotBringTheBarBack() {
        let editor = makeEditor()
        let text = editor.string as NSString
        let start = text.range(of: "First").location
        let end = NSMaxRange(text.range(of: "Second quote"))
        editor.textView.setSelectedRange(NSRange(location: start, length: end - start))
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        #expect(!(fragment(at: "First", in: editor) is QuoteBarFragment))
        #expect(!(fragment(at: "Second", in: editor) is QuoteBarFragment))
        #expect(fragment(at: "Third", in: editor) is QuoteBarFragment)

        select("First", in: editor)
        let storage = editor.textView.textStorage!
        storage.replaceCharacters(in: NSRange(location: start, length: 0), with: "Edited ")
        editor.textView.didChangeText()
        #expect(!(fragment(at: "Edited", in: editor) is QuoteBarFragment))
        let color = storage.attribute(.foregroundColor, at: start, effectiveRange: nil) as! NSColor
        #expect(color.isEqual(editor.theme.mutedColor))
        #expect((storage.attribute(.font, at: start, effectiveRange: nil) as! NSFont).fontName == "Libron-Regular")
    }

    @Test func lazyContinuationUsesQuoteStylingAndBlankLineEndsIt() {
        let editor = makeEditor()
        editor.load(text: "> First\nContinued text\n\nNormal\n")
        select("Normal", in: editor)
        #expect(fragment(at: "First", in: editor) is QuoteBarFragment)
        #expect(fragment(at: "Continued", in: editor) is QuoteBarFragment)
        let storage = editor.textView.textStorage!
        let index = (editor.string as NSString).range(of: "Continued").location
        #expect((storage.attribute(.font, at: index, effectiveRange: nil) as! NSFont).fontName == "Libron-Regular")
        #expect((storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as! NSColor).isEqual(editor.theme.mutedColor))
        #expect(storage.attribute(.noietsHidden, at: index, effectiveRange: nil) == nil)
        select("Continued", in: editor)
        #expect(!(fragment(at: "Continued", in: editor) is QuoteBarFragment))
        editor.textView.replace(NSRange(location: index, length: 0), with: "\n")
        select("Normal", in: editor)
        #expect(!(fragment(at: "Continued", in: editor) is QuoteBarFragment))
        #expect((storage.attribute(.font, at: index + 1, effectiveRange: nil) as! NSFont).familyName != "Libron")
        editor.textView.replace(NSRange(location: index, length: 1), with: "")
        select("Normal", in: editor)
        #expect(fragment(at: "Continued", in: editor) is QuoteBarFragment)
    }

    @Test func rawPreviewAndLockedQuotes() {
        let editor = makeEditor()
        editor.highlighter.livePreviewEnabled = false
        editor.highlighter.restyleAll(editor.textView.textStorage!)
        editor.textView.textLayoutManager!.invalidateLayout(for: editor.textView.textLayoutManager!.documentRange)
        #expect(!(fragment(at: "First", in: editor) is QuoteBarFragment))

        editor.highlighter.livePreviewEnabled = true
        editor.setLocked(true)
        select("First", in: editor)
        #expect(fragment(at: "First", in: editor) is QuoteBarFragment)
        editor.setLocked(false)
        #expect(!(fragment(at: "First", in: editor) is QuoteBarFragment))
    }

    @Test func enteringQuoteFadesOnlyItsBarAndCleansUp() async {
        _ = NSApplication.shared
        // Attach to a hidden window: no appearance override or onscreen test UI.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let editor = makeEditor()
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        #expect(fragment(at: "First", in: editor) is QuoteBarFragment)
        select("First", in: editor)
        let layers = editor.textView.layer?.sublayers?.filter { $0.name == "quoteBarFade" } ?? []
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(layers.isEmpty)
        } else {
            #expect(layers.count == 1)
            #expect(layers.first?.animation(forKey: "quoteBarFade")?.duration == 0.12)
        }
        #expect(!(fragment(at: "First", in: editor) is QuoteBarFragment))
        // Parallel main-actor tests can delay the cleanup task's start.
        // Bound the wait rather than assuming the actor is idle for 250ms.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while editor.textView.layer?.sublayers?.contains(where: { $0.name == "quoteBarFade" }) == true,
              ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(editor.textView.layer?.sublayers?.contains { $0.name == "quoteBarFade" } != true)
        select("Second", in: editor)
        select("After", in: editor) // rapid re-entry/exit must not leave a ghost
        #expect(editor.textView.layer?.sublayers?.contains { $0.name == "quoteBarFade" } != true)
        window.contentView = nil
    }
}
