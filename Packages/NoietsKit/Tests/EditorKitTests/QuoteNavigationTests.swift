import AppKit
import Testing
@testable import EditorKit

@MainActor
struct QuoteNavigationTests {
    private let quote = "> Monks, this saṃsāra is without discoverable beginning. A first point is not discerned of beings roaming and wandering on hindered by ignorance and fettered by craving. Suppose, monks, a man would cut up whatever grass, sticks, branches, and foliage there are in this Jambudīpa and collect them together into a single heap. Having done so, he would put them down, saying for each one: ‘This is my mother, this my mother’s mother.’ The sequence of that man’s mothers and grandmothers would not come to an end, yet the grass, sticks, branches, and foliage in this Jambudīpa would be used up and exhausted. For what reason? Because, monks, this saṃsāra is without discoverable beginning. A first point is not discerned of beings roaming and wandering on hindered by ignorance and fettered by craving. For such a long time, monks, you have experienced suffering, anguish, and disaster, and swelled the cemetery. It is enough to become disenchanted with all formations, enough to become dispassionate toward them, enough to be liberated from them"

    private func makeEditor(width: CGFloat, content: String? = nil) -> (NSWindow, MarkdownEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let editor = MarkdownEditorView()
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        editor.load(text: content ?? ("Body\n\n" + quote + "\n\nAfter\n"))
        window.makeFirstResponder(editor.textView)
        editor.highlighter.restyleAll(editor.textView.textStorage!)
        return (window, editor)
    }

    private func caretRect(in editor: MarkdownEditorView) -> NSRect {
        NSRectFromString(editor.caretDebugInfo["blockFrame"] as! String)
    }

    private func select(_ index: Int, in editor: MarkdownEditorView) {
        editor.textView.selection = NSRange(location: index, length: 0)
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        editor.refreshCaretShape()
    }

    @Test(arguments: [420.0, 816.0])
    func zeroAndDollarStayOnEachWrappedQuoteRow(width: Double) {
        let (window, editor) = makeEditor(width: width)
        defer { window.contentView = nil }
        let text = editor.string as NSString
        let quoteStart = text.range(of: "> ").location
        let quoteEnd = text.range(of: "\n\nAfter").location
        select(quoteStart + 2, in: editor)
        let rows = editor.textView.visualRows().filter { $0.location >= quoteStart && $0.location < quoteEnd }
        for (index, row) in rows.enumerated() {
            let end = index + 1 < rows.count ? rows[index + 1].location : quoteEnd
            select(row.location, in: editor)
            editor.vim.handleKey(.init(characters: "$"))
            #expect(editor.vim.displayCaret == text.rangeOfComposedCharacterSequence(at: end - 1).location)
            #expect(abs(caretRect(in: editor).midY - row.rect.midY) < 5)
            editor.vim.handleKey(.init(characters: "0"))
            #expect(editor.vim.displayCaret == row.location)
            #expect(abs(caretRect(in: editor).midY - row.rect.midY) < 5)
        }
    }

    @Test func visualHeadAndOperatorsUseWrappedBoundsButDoubleDeleteStaysLogical() {
        let (window, editor) = makeEditor(width: 816)
        defer { window.contentView = nil }
        let original = editor.string
        select((original as NSString).range(of: "> ").location + 2, in: editor)
        let rows = editor.textView.visualRows()
        let row = rows[5]
        let end = rows[6].location
        select(row.location + 3, in: editor)
        editor.vim.handleKey(.init(characters: "v"))
        editor.vim.handleKey(.init(characters: "$"))
        #expect(editor.vim.displayCaret == end - 1)
        editor.vim.handleKey(.init(characters: "0"))
        #expect(editor.vim.displayCaret == row.location)
        editor.vim.handleKey(.init(characters: "", isEscape: true))
        for motion in ["0", "$"] {
            select(row.location + 3, in: editor)
            let range = motion == "0" ? NSRange(location: row.location, length: 3)
                : NSRange(location: row.location + 3, length: end - row.location - 3)
            let expected = (original as NSString).replacingCharacters(in: range, with: "")
            editor.vim.handleKey(.init(characters: "d"))
            editor.vim.handleKey(.init(characters: motion))
            #expect(editor.string == expected)
            editor.vim.handleKey(.init(characters: "u"))
            #expect(editor.string == original)
        }
        select(row.location + 3, in: editor)
        let logical = (original as NSString).lineRange(for: NSRange(location: row.location, length: 0))
        editor.vim.handleKey(.init(characters: "d"))
        editor.vim.handleKey(.init(characters: "d"))
        #expect(editor.string == (original as NSString).replacingCharacters(in: logical, with: ""))
    }

    @Test(arguments: ["", "One row\n\n", "One row\r\n", String(repeating: "Հայերեն 😀 é 👩🏽‍💻 ", count: 20) + "👩🏽‍💻"])
    func visualBoundsHandleEmptyRowsAndComposedCharacters(content: String) {
        let (window, editor) = makeEditor(width: 420, content: content)
        defer { window.contentView = nil }
        let text = editor.string as NSString
        let index = text.length == 0 ? 0 : text.length - 1
        select(index, in: editor)
        let row = editor.textView.visualLineRange(at: index)
        editor.vim.handleKey(.init(characters: "$"))
        let expected = row.length == 0 ? row.location : text.rangeOfComposedCharacterSequence(at: NSMaxRange(row) - 1).location
        #expect(editor.vim.displayCaret == expected)
        editor.vim.handleKey(.init(characters: "0"))
        #expect(editor.vim.displayCaret == row.location)
        #expect(editor.textView.textLayoutManager != nil)
    }

    @Test func countedVerticalMovesCorrectQuoteReflowBeforeTheNextStep() {
        let (window, editor) = makeEditor(width: 816)
        defer { window.contentView = nil }
        let text = editor.string as NSString
        let quoteEnd = text.range(of: "\n\nAfter").location
        select(quoteEnd + 1, in: editor)
        editor.vim.handleKey(.init(characters: "2"))
        editor.vim.handleKey(.init(characters: "k"))
        let rows = editor.textView.visualRows().filter { $0.location < quoteEnd }
        #expect(abs(caretRect(in: editor).midY - rows[rows.count - 2].rect.midY) < 5)
        editor.vim.handleKey(.init(characters: "2"))
        editor.vim.handleKey(.init(characters: "j"))
        #expect(editor.vim.displayCaret == quoteEnd + 1)
    }

    @Test(arguments: [320.0, 420.0, 560.0, 640.0, 760.0, 816.0, 900.0])
    func enteringExactQuoteFromBelowLandsOnLastVisualRow(width: Double) {
        let (window, editor) = makeEditor(width: width)
        defer { window.contentView = nil }
        let text = editor.string as NSString
        let quoteStart = text.range(of: "> ").location
        let quoteEnd = text.range(of: "\n\nAfter").location
        let blank = quoteEnd + 1
        editor.textView.selection = NSRange(location: blank, length: 0)
        editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
        editor.refreshCaretShape()
        for _ in 0..<3 {
            editor.vim.handleKey(.init(characters: "k"))
            editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
            let rows = editor.textView.visualRows().filter { $0.location >= quoteStart && $0.location < quoteEnd }
            let destination = caretRect(in: editor)
            #expect(abs(destination.midY - rows.last!.rect.midY) < 5)
            editor.vim.handleKey(.init(characters: "j"))
            editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
            #expect(editor.textView.selectedRange().location == blank)
        }
    }
}
