import AppKit
import EditorKit
import VaultStore

/// Dev-only functional smoke test: NOIETS_SELFTEST=1 makes the app print a
/// JSON diagnostic of its real runtime state to stdout shortly after launch,
/// then exit. Verifies the wiring (vault → tree → sidebar → editor → TextKit 2)
/// without needing pixels or accessibility permissions.
@MainActor
enum SelfTest {
    static func armIfRequested(session: @escaping @autoclosure @MainActor () -> VaultSession?) {
        let env = ProcessInfo.processInfo.environment
        guard env["NOIETS_SELFTEST"] == "1" else { return }
        let delay = Double(env["NOIETS_SELFTEST_DELAY"] ?? "") ?? 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            report(session: session())
            exit(0)
        }
    }

    private static func report(session: VaultSession?) {
        var out: [String: Any] = [:]
        out["vault"] = session?.vault.rootURL.path ?? "<none>"
        out["treeChildren"] = session?.tree.children.map(\.title) ?? []
        out["currentNote"] = session?.currentNoteURL?.lastPathComponent ?? "<none>"

        let window = NSApp.windows.first { $0.isVisible }
        out["windowVisible"] = window != nil
        out["windowFrame"] = window.map { NSStringFromRect($0.frame) } ?? "<none>"

        if let window {
            var textViews: [NSTextView] = []
            var outlines: [NSOutlineView] = []
            func walk(_ view: NSView) {
                if let tv = view as? NSTextView { textViews.append(tv) }
                if let ov = view as? NSOutlineView { outlines.append(ov) }
                view.subviews.forEach(walk)
            }
            if let content = window.contentView { walk(content) }

            if let editor = textViews.first {
                out["editorTextLength"] = editor.string.count
                out["editorFirstLine"] = editor.string.components(separatedBy: "\n").first ?? ""
                out["editorUsesTextKit2"] = editor.textLayoutManager != nil
                out["editorHidden"] = editor.isHiddenOrHasHiddenAncestor
                // Styling proof: font sizes seen across the document. A styled
                // doc with a heading shows >1 distinct size (base 15 + heading).
                if let storage = editor.textStorage, storage.length > 0 {
                    var sizes = Set<CGFloat>()
                    storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                        if let font = value as? NSFont { sizes.insert(font.pointSize) }
                    }
                    out["fontSizes"] = sizes.sorted().map { Double($0) }
                }
            } else {
                out["editorTextLength"] = -1
            }
            if let editor = textViews.first {
                out["livePreview"] = livePreviewChecks(editor)
            }
            if let editorView = findEditorView(in: window) {
                out["vim"] = vimChecks(editorView)
            }
            if let session = session {
                out["index"] = indexChecks(session)
            }
            if ProcessInfo.processInfo.environment["NOIETS_PERF"] == "1",
               let editorView = findEditorView(in: window), let session = session {
                out["perf"] = perfChecks(editorView, session: session)
            }
            if let wc = window.windowController as? MainWindowController {
                out["palette"] = paletteChecks(wc)
                if let editorView = findEditorView(in: window), let session = session {
                    out["wiki"] = wikiChecks(wc, editorView, vault: session.vault.rootURL)
                }
            }
            if let outline = outlines.first {
                out["sidebarRows"] = outline.numberOfRows
                out["sidebarSelectedRow"] = outline.selectedRow
            } else {
                out["sidebarRows"] = -1
            }
        }

        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
        print("NOIETS_SELFTEST_BEGIN")
        print(String(data: data, encoding: .utf8) ?? "{}")
        print("NOIETS_SELFTEST_END")
    }

    /// Exercises Live Preview end to end inside the real editor: markers are
    /// hidden while the paragraph is inactive, revealed when the caret enters,
    /// re-hidden when it leaves.
    private static func livePreviewChecks(_ editor: NSTextView) -> [String: Any] {
        var result: [String: Any] = [:]
        guard let storage = editor.textStorage else { return ["error": "no storage"] }
        let text = editor.string as NSString
        let boldMarker = text.range(of: "**Bold**")
        guard boldMarker.location != NSNotFound else { return ["error": "no bold sample"] }

        func isHidden(_ index: Int) -> Bool {
            guard index < storage.length else { return false }
            return storage.attribute(.noietsHidden, at: index, effectiveRange: nil) != nil
        }

        editor.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        result["hiddenWhileInactive"] = isHidden(boldMarker.location)

        // Caret into the bold word → paragraph becomes active → markers reveal.
        editor.setSelectedRange(NSRange(location: boldMarker.location + 3, length: 0))
        result["revealedWhenActive"] = !isHidden(boldMarker.location)

        // Leave again → re-hidden.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        result["reHiddenAfterLeave"] = isHidden(boldMarker.location)

        // Caret skip: place the caret right before the hidden `**` and step
        // forward via the real movement selector (user path → snap applies).
        editor.setSelectedRange(NSRange(location: boldMarker.location, length: 0))
        // (paragraph became active by the placement — move away first)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.moveDown(nil)
        result["caretAfterMoveDown"] = editor.selectedRange().location

        return result
    }

    private static func findEditorView(in window: NSWindow) -> MarkdownEditorView? {
        func walk(_ view: NSView) -> MarkdownEditorView? {
            if let e = view as? MarkdownEditorView { return e }
            for sub in view.subviews {
                if let found = walk(sub) { return found }
            }
            return nil
        }
        guard let content = window.contentView else { return nil }
        return walk(content)
    }

    /// Drives vim through real keyDown events on the actual text view —
    /// exercises key routing, the engine, the undo pipeline, and live preview
    /// in one pass. Detaches autosave first so test edits never reach disk.
    private static func vimChecks(_ editorView: MarkdownEditorView) -> [String: Any] {
        var result: [String: Any] = [:]
        let tv = editorView.textView
        let vim = editorView.vim
        editorView.onTextChange = nil // IMPORTANT: keep test edits off disk
        editorView.window?.makeFirstResponder(tv)

        func key(_ ch: String, keyCode: UInt16 = 0, control: Bool = false) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: control ? [.control] : [],
                timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0, context: nil,
                characters: ch, charactersIgnoringModifiers: ch,
                isARepeat: false, keyCode: keyCode
            ) else { return }
            tv.keyDown(with: event)
        }
        func keys(_ s: String) { s.forEach { key(String($0)) } }
        func esc() { key("\u{1B}", keyCode: 53) }
        func line1() -> String { tv.string.components(separatedBy: "\n").first ?? "" }

        result["startsInNormal"] = vim.mode == .normal

        editorView.load(text: "alpha beta gamma\nsecond line here\n")
        keys("dw")
        result["afterDW"] = line1() // "beta gamma"
        keys("u")
        result["afterUndo"] = line1() // "alpha beta gamma"
        key("r", control: true)
        result["afterRedo"] = line1() // "beta gamma"

        keys("ciw")
        result["modeAfterCIW"] = vim.mode.label
        tv.insertText("X", replacementRange: tv.selectedRange())
        esc()
        result["afterCIWTyped"] = line1() // "X gamma"
        keys("w.")
        result["afterDotRepeat"] = line1() // "X X"

        keys("Vd")
        result["afterVisualLineDelete"] = line1() // "second line here"

        keys("/here\n")
        result["searchLandedAt"] = tv.selectedRange().location // 12

        // Caret shape: block (native caret cleared) in normal, bar in insert.
        result["normalCaretCleared"] = tv.insertionPointColor.alphaComponent == 0
        key("i")
        result["insertCaretVisible"] = tv.insertionPointColor.alphaComponent > 0
        esc()

        // ⌃d half-page scroll through the real key path.
        editorView.load(text: (1...80).map { "line \($0)" }.joined(separator: "\n"))
        guard let ctrlD = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control],
            timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0, context: nil,
            characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2
        ) else { return result }
        tv.keyDown(with: ctrlD)
        result["ctrlDMovedTo"] = tv.selectedRange().location

        editorView.load(text: "restored\n")
        return result
    }

    /// Index sanity against the live vault (after startup reconcile).
    private static func indexChecks(_ session: VaultSession) -> [String: Any] {
        guard let index = session.index else { return ["error": "no index"] }
        var result: [String: Any] = [:]
        result["noteCount"] = (try? index.allNotes().count) ?? -1
        result["searchVimHits"] = (try? index.searchNotes("vim").count) ?? -1
        result["quickOpenWel"] = (try? index.quickOpen("wel").map(\.title)) ?? []
        result["recentCount"] = (try? index.recentNotes().count) ?? -1
        result["tags"] = (try? index.allTags().map(\.name)) ?? []
        return result
    }

    /// Opens and closes the quick-open overlay through the real action.
    private static func paletteChecks(_ wc: MainWindowController) -> [String: Any] {
        var result: [String: Any] = [:]
        wc.quickOpen(nil)
        result["quickOpenVisible"] = PalettePanel.shared.isVisible
        PalettePanel.shared.dismiss()
        result["dismissed"] = !PalettePanel.shared.isVisible
        return result
    }

    /// Wiki-link routing (create-on-missing) + [[ autocompletion end to end.
    private static func wikiChecks(
        _ wc: MainWindowController,
        _ editorView: MarkdownEditorView,
        vault: URL
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        let tv = editorView.textView

        // 1. Clicking an unresolved [[Second Note]] creates + opens the note.
        _ = editorView.textView(tv, clickedOnLink: "noiets://open/Second%20Note" as Any, at: 0)
        let created = vault.appendingPathComponent("Second Note.md")
        result["createOnMissing"] = FileManager.default.fileExists(atPath: created.path)
        result["openedTitle"] = wc.window?.title ?? ""

        // 2. Typing "[[We" pops completion; Return inserts "[[Welcome to Noiets]]".
        editorView.onTextChange = nil // keep the scratch edit off disk
        editorView.load(text: "start ")
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        func key(_ ch: String, keyCode: UInt16 = 0) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0, context: nil,
                characters: ch, charactersIgnoringModifiers: ch,
                isARepeat: false, keyCode: keyCode
            ) else { return }
            tv.keyDown(with: event)
        }
        key("i") // vim → insert mode
        tv.insertText("[[We", replacementRange: tv.selectedRange())
        result["completionVisible"] = editorView.isWikiCompletionActive
        key("\r", keyCode: 36)
        result["afterCompletion"] = tv.string
        return result
    }

    /// Perf gates from the plan: a 10k-word note must type smoothly, and a
    /// big vault must search fast.
    private static func perfChecks(_ editorView: MarkdownEditorView, session: VaultSession) -> [String: Any] {
        var result: [String: Any] = [:]
        let tv = editorView.textView
        editorView.onTextChange = nil

        // Build ~10k words of mixed markdown.
        var doc = "# Big Note\n\n"
        for i in 0..<500 {
            doc += "## Section \(i % 40)\n\nSome **bold** text with a [[Link \(i)]] and `code_\(i)` plus #tag\(i % 25) filler words here to bulk the line out properly.\n\n- item one\n- item two\n\n"
        }
        result["docWords"] = doc.split(separator: " ").count

        let loadStart = Date()
        editorView.load(text: doc)
        result["loadMs"] = Int(Date().timeIntervalSince(loadStart) * 1000)

        // Simulate 60 keystrokes mid-document through the full pipeline.
        let mid = (doc as NSString).length / 2
        let insertAt = (doc as NSString).lineRange(for: NSRange(location: mid, length: 0)).location
        tv.setSelectedRange(NSRange(location: insertAt, length: 0))
        let typeStart = Date()
        for ch in "the quick brown fox jumps over the lazy dog and keeps going!" {
            tv.insertText(String(ch), replacementRange: tv.selectedRange())
        }
        let elapsed = Date().timeIntervalSince(typeStart) * 1000
        result["keystrokes"] = 61
        result["typingTotalMs"] = Int(elapsed)
        result["perKeystrokeMs"] = Double(Int(elapsed / 61 * 100)) / 100

        // Search latency on whatever the index currently holds.
        if let index = session.index {
            let searchStart = Date()
            let hits = (try? index.searchNotes("filler")) ?? []
            result["searchMs"] = Int(Date().timeIntervalSince(searchStart) * 1000)
            result["searchHits"] = hits.count
        }

        editorView.load(text: "restored\n")
        return result
    }
}
