import AppKit
import Testing
@testable import EditorKit

@MainActor
struct SmoothScrollingTests {
    private func makeEditor() -> (NSWindow, MarkdownEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let editor = MarkdownEditorView()
        window.contentView = editor
        editor.layoutSubtreeIfNeeded()
        editor.load(text: (0..<150).map { "Line \($0) of the document." }.joined(separator: "\n"))
        window.makeFirstResponder(editor.textView)
        editor.textView.textLayoutManager!.ensureLayout(for: editor.textView.textLayoutManager!.documentRange)
        editor.textView.scrollCaretToVisible()
        return (window, editor)
    }

    @Test func halfPageInterpolatesRealViewportAndRepeatedPressesAccumulate() {
        let (window, editor) = makeEditor()
        defer { window.contentView = nil }
        let view = editor.textView
        let clip = view.enclosingScrollView!.contentView
        let original = clip.bounds.origin.y
        editor.vim.handleKey(.init(characters: "d", hasControl: true))
        #expect(editor.vim.displayCaret > 0)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(!view.isSmoothScrolling)
            #expect(clip.bounds.origin.y > original)
            return
        }
        #expect(view.isSmoothScrolling)
        #expect(abs(clip.bounds.origin.y - original) < 1)
        view.stepSmoothScroll(at: CACurrentMediaTime() + 0.04)
        let intermediate = clip.bounds.origin.y
        #expect(intermediate > original)
        editor.vim.handleKey(.init(characters: "d", hasControl: true))
        #expect(abs(clip.bounds.origin.y - intermediate) < 1)
        view.stepSmoothScroll(at: CACurrentMediaTime() + 1)
        let final = clip.bounds.origin.y
        #expect(final > intermediate)
        #expect(!view.isSmoothScrolling)
        let caret = NSRectFromString(editor.caretDebugInfo["blockFrame"] as! String)
        #expect(abs(caret.minY - final - 28) < 5)
        editor.vim.handleKey(.init(characters: "u", hasControl: true))
        view.stepSmoothScroll(at: CACurrentMediaTime() + 1)
        #expect(clip.bounds.origin.y < final)
    }

    @Test func realTimerFinishesAndVisualModeScrollsTheHead() async {
        let (window, editor) = makeEditor()
        defer { window.contentView = nil }
        let view = editor.textView
        let clip = view.enclosingScrollView!.contentView
        editor.vim.handleKey(.init(characters: "v"))
        editor.vim.handleKey(.init(characters: "d", hasControl: true))
        #expect(editor.vim.displayCaret > 0)
        #expect(view.selectedRange().location == 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while view.isSmoothScrolling, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!view.isSmoothScrolling)
        #expect(clip.bounds.origin.y > 0)
        #expect(view.textLayoutManager != nil)
    }

    @Test func reversalNormalMotionNoteLoadAndDetachCancelCleanly() {
        let (window, editor) = makeEditor()
        defer { window.contentView = nil }
        let view = editor.textView
        let clip = view.enclosingScrollView!.contentView
        editor.vim.handleKey(.init(characters: "d", hasControl: true))
        view.stepSmoothScroll(at: CACurrentMediaTime() + 0.04)
        let intermediate = clip.bounds.origin.y
        editor.vim.handleKey(.init(characters: "u", hasControl: true))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(abs(clip.bounds.origin.y - intermediate) < 1)
        }
        view.stepSmoothScroll(at: CACurrentMediaTime() + 1)
        #expect(abs(clip.bounds.origin.y) < 1)
        editor.vim.handleKey(.init(characters: "d", hasControl: true))
        editor.vim.handleKey(.init(characters: "j"))
        #expect(!view.isSmoothScrolling)
        editor.vim.handleKey(.init(characters: "d", hasControl: true))
        editor.load(text: "New note")
        #expect(!view.isSmoothScrolling)
        editor.load(text: String(repeating: "Row\n", count: 100))
        editor.vim.handleKey(.init(characters: "d", hasControl: true))
        window.contentView = nil
        #expect(!view.isSmoothScrolling)
    }
}
