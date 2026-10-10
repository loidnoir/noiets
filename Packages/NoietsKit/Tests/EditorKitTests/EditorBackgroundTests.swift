import AppKit
import Testing
@testable import EditorKit

@MainActor
struct EditorBackgroundTests {
    @Test func transparencyTogglesBackingSurfacesNotTextAndSurvivesColorRefresh() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let editor = MarkdownEditorView()
        window.contentView = editor
        defer { window.contentView = nil }
        editor.layoutSubtreeIfNeeded()
        editor.load(text: "Body\n\n> Wrapped quote text\n\nAfter\n")
        window.makeFirstResponder(editor.textView)
        editor.textView.selection = NSRange(location: 1, length: 0)
        editor.vim.handleKey(.init(characters: "x"))
        let edited = editor.string
        let selection = editor.textView.selection
        let mode = editor.vim.mode
        let viewport = editor.scrollView.contentView.bounds.origin
        var edits = 0
        editor.onTextChange = { edits += 1 }
        #expect(!editor.isBackgroundTransparent)
        #expect(editor.textView.drawsBackground)
        #expect(editor.scrollView.drawsBackground)
        editor.isBackgroundTransparent = true
        editor.refreshThemeColors()
        #expect(!editor.textView.drawsBackground)
        #expect(!editor.scrollView.drawsBackground)
        #expect(!editor.scrollView.contentView.drawsBackground)
        #expect(editor.textView.backgroundColor.isEqual(NSColor.clear))
        #expect(editor.alphaValue == 1)
        #expect(editor.textView.alphaValue == 1)
        #expect(editor.scrollView.alphaValue == 1)
        #expect(editor.string == edited)
        #expect(editor.textView.selection == selection)
        #expect(editor.vim.mode == mode)
        #expect(editor.scrollView.contentView.bounds.origin == viewport)
        #expect(edits == 0)
        #expect(editor.textView.textLayoutManager != nil)
        editor.isBackgroundTransparent = false
        #expect(editor.textView.drawsBackground)
        #expect(editor.scrollView.drawsBackground)
        #expect(editor.scrollView.contentView.drawsBackground)
        #expect(editor.textView.backgroundColor.isEqual(editor.theme.background))
        editor.vim.handleKey(.init(characters: "u"))
        #expect(editor.string.hasPrefix("Body"))
    }
}
