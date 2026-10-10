import AppKit
import Testing
@testable import EditorKit

@MainActor
struct CodeSelectionTests {
    private let markdown = "Before\n\n```bash\necho hello\n\nprintf '%s' \"a long code line that wraps onto another displayed row in this narrow editor\"\n```\n\nAfter\n"

    private func makeEditor(transparent: Bool = false) -> (NSWindow, MarkdownEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let editor = MarkdownEditorView()
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        editor.isBackgroundTransparent = transparent
        editor.load(text: markdown)
        window.makeFirstResponder(editor.textView)
        editor.highlighter.restyleAll(editor.textView.textStorage!)
        return (window, editor)
    }

    private func sample(in editor: MarkdownEditorView, at point: CGPoint) -> NSColor {
        let tv = editor.textView
        let rect = tv.bounds
        let rep = tv.bitmapImageRepForCachingDisplay(in: rect)!
        tv.cacheDisplay(in: rect, to: rep)
        let x = Int((point.x - rect.minX) * CGFloat(rep.pixelsWide) / rect.width)
        let y = Int((point.y - rect.minY) * CGFloat(rep.pixelsHigh) / rect.height)
        return rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }

    private func trailingPoint(on row: NSRect, in editor: MarkdownEditorView) -> CGPoint {
        CGPoint(x: editor.textView.textContainerOrigin.x + editor.textView.textContainer!.size.width - 30,
                y: row.midY)
    }

    private func sampleCodeBlank(in editor: MarkdownEditorView) -> NSColor {
        let index = (editor.string as NSString).range(of: "\n\nprintf").location + 1
        let row = editor.textView.visualRows().first { $0.location == index }!
        return sample(in: editor, at: trailingPoint(on: row.rect, in: editor))
    }

    private func difference(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        abs(lhs.redComponent - rhs.redComponent) + abs(lhs.greenComponent - rhs.greenComponent)
            + abs(lhs.blueComponent - rhs.blueComponent) + abs(lhs.alphaComponent - rhs.alphaComponent)
    }

    @Test(arguments: [false, true])
    func visualLineSelectionIsVisibleOverCodeBackground(transparent: Bool) {
        let (window, editor) = makeEditor(transparent: transparent)
        defer { window.contentView = nil }
        let before = sampleCodeBlank(in: editor)
        let bodyRow = editor.textView.visualRows().first!
        let body = sample(in: editor, at: trailingPoint(on: bodyRow.rect, in: editor))
        #expect(difference(before, body) > 0.05, "Unselected code must retain its distinct background")
        #expect(before.alphaComponent > 0.95, "Code bands remain opaque even in glass mode")
        editor.textView.selection = NSRange(location: 0, length: 0)
        editor.vim.handleKey(.init(characters: "V"))
        editor.vim.handleKey(.init(characters: "4"))
        editor.vim.handleKey(.init(characters: "j"))
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        let selected = editor.textView.selectedRange()
        #expect((editor.string as NSString).substring(with: selected).contains("echo hello\n\n"))
        #expect(difference(before, sampleCodeBlank(in: editor)) > 0.05,
                "Code background must not conceal the native selection")
        editor.vim.handleKey(.init(characters: "", isEscape: true))
        #expect(difference(before, sampleCodeBlank(in: editor)) < 0.03)
        #expect(editor.textView.textLayoutManager != nil)
        #expect(editor.string == markdown)
    }

    @Test func visualLineHighlightsTheLastWrappedCodeRow() {
        let (window, editor) = makeEditor()
        defer { window.contentView = nil }
        let text = editor.string as NSString
        let start = text.range(of: "printf").location
        let range = text.lineRange(for: NSRange(location: start, length: 0))
        let rows = editor.textView.visualRows().filter { NSLocationInRange($0.location, range) }
        #expect(rows.count > 1)
        let point = trailingPoint(on: rows.last!.rect, in: editor)
        let before = sample(in: editor, at: point)
        editor.textView.selection = NSRange(location: start, length: 0)
        editor.vim.handleKey(.init(characters: "V"))
        #expect(editor.textView.selectedRange() == range)
        #expect(difference(before, sample(in: editor, at: point)) > 0.05)
    }

    @Test func fenceEditsRepaintCodeBandsBeyondTheEditedLine() {
        let (window, editor) = makeEditor(transparent: true)
        defer { window.contentView = nil }
        let tv = editor.textView
        let text = editor.string as NSString
        let after = text.range(of: "After").location
        let bodyRow = tv.visualRows().first { $0.location == after }!
        let before = sample(in: editor, at: trailingPoint(on: bodyRow.rect, in: editor))
        tv.needsDisplay = false
        tv.replace(NSRange(location: text.range(of: "\n```\n").location + 1, length: 3), with: "")
        #expect(tv.needsDisplay)
        let codeAfter = (editor.string as NSString).range(of: "After").location
        let codeRow = tv.visualRows().first { $0.location == codeAfter }!
        let painted = sample(in: editor, at: trailingPoint(on: codeRow.rect, in: editor))
        #expect(difference(before, painted) > 0.05)
        #expect(painted.alphaComponent > 0.95)
    }

    @Test(arguments: [false, true])
    func characterwiseVisualSelectionWorksInBothDirections(backwards: Bool) {
        let (window, editor) = makeEditor()
        defer { window.contentView = nil }
        // Sample interior whitespace, away from the visual head at either edge.
        let start = (editor.string as NSString).range(of: "echo hello").location
        let content = editor.textView.textContentStorage!
        let location = content.location(content.documentRange.location, offsetBy: start + 4)!
        let end = content.location(location, offsetBy: 1)!
        var space = CGRect.zero
        editor.textView.textLayoutManager!.ensureLayout(for: editor.textView.textLayoutManager!.documentRange)
        editor.textView.textLayoutManager!.enumerateTextSegments(in: NSTextRange(location: location, end: end)!,
                                                                type: .selection, options: []) { _, rect, _, _ in
            space = rect
            return false
        }
        #expect(!space.isEmpty)
        let origin = editor.textView.textContainerOrigin
        let point = CGPoint(x: space.midX + origin.x, y: space.midY + origin.y)
        let before = sample(in: editor, at: point)
        editor.textView.selection = NSRange(location: start + (backwards ? 9 : 0), length: 0)
        editor.vim.handleKey(.init(characters: "v"))
        editor.vim.handleKey(.init(characters: "9"))
        editor.vim.handleKey(.init(characters: backwards ? "h" : "l"))
        #expect(editor.textView.selectedRange() == NSRange(location: start, length: 10))
        // Animated trails are separate overlays: they must not make a hidden
        // selection look highlighted in this pixel-level assertion.
        editor.textView.layer?.sublayers?.filter { $0.name == "caretSmear" }.forEach { $0.removeFromSuperlayer() }
        #expect(difference(before, sample(in: editor, at: point)) > 0.05)
    }
}
