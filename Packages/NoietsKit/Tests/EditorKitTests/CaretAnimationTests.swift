import AppKit
import Testing
@testable import EditorKit

@MainActor
struct CaretAnimationTests {
    private func makeEditor() -> (NSWindow, MarkdownEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let editor = MarkdownEditorView()
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        editor.load(text: "Body\n\n> " + String(repeating: "The quote is one long logical line with several visual rows. ", count: 7) + "\n\nAfter\n")
        window.makeFirstResponder(editor.textView)
        editor.highlighter.restyleAll(editor.textView.textStorage!)
        return (window, editor)
    }

    private func select(_ index: Int, in editor: MarkdownEditorView) {
        editor.textView.selection = NSRange(location: index, length: 0)
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        editor.refreshCaretShape()
    }

    private func frame(in editor: MarkdownEditorView) -> NSRect {
        NSRectFromString(editor.caretDebugInfo["blockFrame"] as! String)
    }

    private func smearPaths(in editor: MarkdownEditorView) -> [CGPath] {
        (editor.textView.layer?.sublayers ?? []).compactMap { layer in
            guard let animation = layer.animation(forKey: "smear") as? CAAnimationGroup,
                  let path = animation.animations?.first as? CABasicAnimation else { return nil }
            guard let value = path.fromValue else { return nil }
            return (value as! CGPath)
        }
    }

    private func clearSmears(in editor: MarkdownEditorView) {
        for layer in editor.textView.layer?.sublayers ?? [] where layer.animation(forKey: "smear") != nil {
            layer.removeFromSuperlayer()
        }
    }

    @Test func quoteExitTrailStartsAtTheActualWrappedRow() async {
        let (window, editor) = makeEditor()
        defer { window.contentView = nil }
        let text = editor.string as NSString
        let quoteStart = text.range(of: "> ").location
        select(quoteStart + 2, in: editor)
        let rows = editor.textView.visualRows().filter { $0.location >= quoteStart && $0.location < text.range(of: "\n\nAfter").location }
        #expect(rows.count >= 4)
        guard rows.count >= 4 else { return }
        select(rows[3].location + 2, in: editor)
        let old = frame(in: editor)
        #expect(old.minY > rows[0].rect.maxY)
        clearSmears(in: editor)
        select(text.range(of: "After").location, in: editor)
        let destination = frame(in: editor)
        #expect(destination.minY > old.minY)
        for path in smearPaths(in: editor) {
            #expect(abs(path.boundingBoxOfPath.minY - old.minY) < 1)
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(smearPaths(in: editor).count == 1)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(abs(frame(in: editor).minY - destination.minY) < 1)
        // Other main-actor tests can delay this check past the fade's end;
        // a settled layout must never create an additional trail.
        #expect(smearPaths(in: editor).count <= 1)
        for path in smearPaths(in: editor) {
            #expect(abs(path.boundingBoxOfPath.minY - old.minY) < 1)
        }
    }

    @Test func movingUpIntoQuoteFromBlankHasOneShortTrail() {
        let (window, editor) = makeEditor()
        defer { window.contentView = nil }
        let text = editor.string as NSString
        let blank = text.range(of: "\n\nAfter").location + 1
        select(blank, in: editor)
        let old = frame(in: editor)
        clearSmears(in: editor)
        editor.vim.handleKey(.init(characters: "k"))
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        let destination = frame(in: editor)
        let quoteStart = text.range(of: "> ").location
        let rows = editor.textView.visualRows().filter { $0.location >= quoteStart && $0.location < blank - 1 }
        #expect(destination.minY < old.minY)
        #expect(abs(destination.midY - rows.last!.rect.midY) < 5)
        for path in smearPaths(in: editor) {
            #expect(abs(path.boundingBoxOfPath.maxY - old.maxY) < 1)
            #expect(path.boundingBoxOfPath.width < 50)
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(smearPaths(in: editor).count == 1)
        }
    }

    @Test func layoutOnlyUpdatesAndNoteLoadsDoNotCreateTrails() async {
        let (window, editor) = makeEditor()
        defer { window.contentView = nil }
        let text = editor.string as NSString
        select(text.range(of: "> ").location + 2, in: editor)
        clearSmears(in: editor)
        let manager = editor.textView.textLayoutManager!
        manager.invalidateLayout(for: manager.documentRange)
        editor.refreshCaretShape()
        editor.textView.frame.size.height += 1
        #expect(smearPaths(in: editor).isEmpty)
        select(text.range(of: "After").location, in: editor)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(smearPaths(in: editor).count == 1)
        }
        editor.load(text: "Different note\n")
        editor.refreshCaretShape()
        #expect(smearPaths(in: editor).isEmpty)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(smearPaths(in: editor).isEmpty)
    }

    @Test func verticalMoveWithinWrappedQuoteHasNoHorizontalDetour() {
        let (window, editor) = makeEditor()
        defer { window.contentView = nil }
        let quoteStart = (editor.string as NSString).range(of: "> ").location
        select(quoteStart + 2, in: editor)
        let rows = editor.textView.visualRows().filter { $0.location >= quoteStart }
        #expect(rows.count >= 5)
        guard rows.count >= 5 else { return }
        select(rows[3].location + 2, in: editor)
        let old = frame(in: editor)
        clearSmears(in: editor)
        editor.vim.handleKey(.init(characters: "j"))
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        let destination = frame(in: editor)
        #expect(destination.minY > old.minY)
        for path in smearPaths(in: editor) {
            #expect(abs(path.boundingBoxOfPath.minY - old.minY) < 1)
            #expect(path.boundingBoxOfPath.width < 50)
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(smearPaths(in: editor).count == 1)
        }
    }
}
