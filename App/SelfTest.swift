import AppKit
import EditorKit
import IndexKit
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
        // Kick a remote image fetch now; the report checks the cache later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let window = NSApp.windows.first(where: { $0.isVisible }),
               let editorView = findEditorView(in: window) {
                _ = editorView.layoutController?.imageProvider.image(forPath: Self.remoteProbeURL)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            report(session: session())
            exit(0)
        }
    }

    /// Trash → restore round-trip: back to the origin folder while it exists,
    /// vault root once it is gone.
    private static func trashRestoreChecks(_ session: VaultSession) -> [String: Any] {
        var result: [String: Any] = [:]
        let fm = FileManager.default
        let vault = session.vault
        let sub = vault.rootURL.appendingPathComponent("RestoreProbe", isDirectory: true)
        do {
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            let a = try NoteIO.createNote(in: sub, baseName: "RestoreA")
            let b = try NoteIO.createNote(in: sub, baseName: "RestoreB")
            let trashedA = try NoteIO.moveToTrash(a, vault: vault)
            let trashedB = try NoteIO.moveToTrash(b, vault: vault)

            let backA = try NoteIO.restoreFromTrash(trashedA, vault: vault)
            result["toOrigin"] = backA.deletingLastPathComponent().standardizedFileURL
                == sub.standardizedFileURL ? "PASS" : "FAIL: \(backA.path)"

            try fm.removeItem(at: sub) // origin gone → root fallback
            let backB = try NoteIO.restoreFromTrash(trashedB, vault: vault)
            result["missingDirToRoot"] = backB.deletingLastPathComponent().standardizedFileURL
                == vault.rootURL.standardizedFileURL ? "PASS" : "FAIL: \(backB.path)"
            try? fm.removeItem(at: backB)
        } catch {
            result["error"] = "FAIL: \(error)"
        }
        try? fm.removeItem(at: sub)
        return result
    }

    private static let remoteProbeURL =
        "https://www.google.com/images/branding/googlelogo/2x/googlelogo_color_272x92dp.png"

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
                // Non-nil now = the 0.5s-kick download landed and cached.
                out["remoteImageCached"] =
                    editorView.layoutController?.imageProvider.image(forPath: remoteProbeURL) != nil
            }
            if let session = session {
                out["index"] = indexChecks(session)
                out["trashRestore"] = trashRestoreChecks(session)
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
            if let split = window.contentViewController as? NSSplitViewController,
               let sidebar = split.splitViewItems.first?.viewController as? SidebarViewController {
                out["sidebar"] = sidebar.sidebarDebugInfo
            }
            if let wc = window.windowController as? MainWindowController,
               let editorView = findEditorView(in: window) {
                out["images"] = imageResolutionChecks(wc, editorView)
                out["paneNav"] = paneNavChecks(wc, editorView, window: window)
                out["views"] = viewsChecks(wc, editorView, window: window)
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

        // Caret shape: block overlay + hidden indicator in normal, bar in insert.
        result["normalCaret"] = editorView.caretDebugInfo
        key("i")
        result["insertCaretVisible"] = tv.insertionPointColor.alphaComponent > 0
        result["insertBlockHidden"] = (editorView.caretDebugInfo["blockVisible"] as? Bool) == false
        esc()

        // Visual j: on a soft-wrapped single logical line, j must land on the
        // next RENDERED line — i.e. still inside the same logical line.
        let longLine = String(repeating: "wrap around this text ", count: 40)
        editorView.load(text: longLine + "\nsecond line")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        key("j")
        let caretAfterJ = tv.selectedRange().location
        result["visualJStaysInLogicalLine"] = caretAfterJ > 0
            && caretAfterJ < (longLine as NSString).length
        key("j")
        result["visualJProgresses"] = tv.selectedRange().location > caretAfterJ

        // Sticky column: long → short → long lines. The column must clamp on
        // the short line but be REMEMBERED and restored on the next long one.
        editorView.load(text: "aaaaaaaaaaaaaaaaaaaa\nab\ncccccccccccccccccccc")
        tv.setSelectedRange(NSRange(location: 15, length: 0)) // col 15, line 1
        key("j") // short line: clamps near its end
        let colOnShort = tv.selectedRange().location - 21
        key("j") // long line again: should restore ≈ col 15
        let colRestored = tv.selectedRange().location - 24
        result["stickyClampsOnShort"] = colOnShort <= 2
        result["stickyRestores"] = abs(colRestored - 15) <= 1
        key("k")
        key("k") // back on line 1: still ≈ col 15
        result["stickyRestoresUpward"] = abs(tv.selectedRange().location - 15) <= 1

        // j from a mid-line column onto an EMPTY line must land on it (and
        // continue restoring the column past it).
        editorView.load(text: "aaaaaaaaaa\n\nbbbbbbbbbb")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        key("j")
        let onEmpty = tv.selectedRange().location
        key("j")
        let onThird = tv.selectedRange().location
        key("k")
        let backOnEmpty = tv.selectedRange().location
        result["emptyLineTrace"] = [onEmpty, onThird, backOnEmpty] // want [11, ~17, 11]
        result["jLandsOnEmptyLine"] = onEmpty == 11
        result["jThroughEmptyRestores"] = abs(onThird - 17) <= 1
        result["kBackOntoEmpty"] = backOnEmpty == 11

        // Same, but with the real-world ingredients: a WRAPPED paragraph above
        // the empty line, and a styled heading (extra paragraph spacing).
        let wrapped = String(repeating: "wrap this text ", count: 30)
        editorView.load(text: wrapped + "\n\nend")
        let wrappedLen = (wrapped as NSString).length
        tv.setSelectedRange(NSRange(location: wrappedLen - 5, length: 0)) // last visual row
        key("j")
        result["wrapThenEmpty"] = tv.selectedRange().location // want wrappedLen + 1
        result["wrapThenEmptyExpected"] = wrappedLen + 1

        editorView.load(text: "# Heading here\n\nbody text")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        key("j")
        result["headingThenEmpty"] = tv.selectedRange().location // want 15

        // Large-x goal onto an empty line (the reported case: mid/late column
        // of wide prose, empty line below).
        let wide = String(repeating: "abcdefgh ", count: 8) // ~72 chars, unwrapped
        editorView.load(text: wide + "\n\n" + wide)
        let wideLen = (wide as NSString).length
        tv.setSelectedRange(NSRange(location: wideLen - 4, length: 0)) // near line end
        key("j")
        result["bigXOntoEmpty"] = tv.selectedRange().location // want wideLen + 1
        result["bigXOntoEmptyExpected"] = wideLen + 1
        key("j")
        // The goal is pixel-based; with wrapping the exact char index varies
        // with pane width. What must hold: we crossed ONTO line 3 (not stuck,
        // not skipped) at a non-zero column (goal survived the empty line).
        let below = tv.selectedRange().location
        result["bigXBelowRaw"] = below
        result["bigXRestoresBelow"] = below > wideLen + 2 && below <= wideLen + 2 + wideLen

        // j on a soft-wrapped line INSIDE a code block, straight after load
        // (regression: the caret refused to move down until an edit).
        editorView.load(text: "before\n```bash\nsudo /opt/parallelcluster/scripts/"
            + "directory_service/update_directory_service_password.sh "
            + "--extra-flags-to-force-a-soft-wrap=true --more=yes\n```\nafter\n")
        let sudoLoc = (tv.string as NSString).range(of: "sudo").location
        tv.setSelectedRange(NSRange(location: sudoLoc, length: 0))
        key("j")
        let afterCodeJ = tv.selectedRange().location
        result["codeWrapJTrace"] = [sudoLoc, afterCodeJ]
        result["codeWrapJMoves"] = afterCodeJ > sudoLoc + 20

        // * / # word search + :N go-to-line with the transient gutter.
        editorView.load(text: "token beta\nother line\ntoken end\nfour\nfive")
        tv.setSelectedRange(NSRange(location: 2, length: 0)) // inside "token"
        key("*")
        result["starJumpsToNextToken"] = tv.selectedRange().location == 22
        key("#")
        result["hashJumpsBack"] = tv.selectedRange().location == 0

        key(":")
        result["gutterShownOnColon"] = editorView.isLineNumberGutterActive
        keys("4")
        key("\r", keyCode: 36)
        result["gutterHiddenAfterReturn"] = !editorView.isLineNumberGutterActive
        result["colonWentToLine4"] = tv.selectedRange().location == 32 // "four"

        // Wrapped rows count as lines: a soft-wrapped paragraph yields more
        // visual rows than logical lines, and :2 lands INSIDE it (row 2).
        let wrapProse = String(repeating: "count wrapped rows too ", count: 25)
        editorView.load(text: wrapProse + "\ntail")
        let rowCount = tv.visualRows().count
        result["visualRowsExceedLogical"] = rowCount > 2
        keys(":2")
        key("\r", keyCode: 36)
        let row2 = tv.selectedRange().location
        result["colonUsesVisualRows"] = row2 > 0 && row2 < (wrapProse as NSString).length

        // Regression: caret parked exactly at a soft-wrap boundary (start of
        // a wrapped row) must still move DOWN with j — the affinity bug made
        // moveDown land on the row the caret already displayed.
        let wrapList = "- **Adapter** " + String(repeating: "bridges data and views ", count: 12)
        editorView.load(text: wrapList + "\nnext line")
        let vRows = tv.visualRows()
        if vRows.count >= 3 {
            tv.setSelectedRange(NSRange(location: vRows[1].location, length: 0))
            key("j")
            result["jFromWrapBoundary"] = tv.selectedRange().location >= vRows[2].location
        } else {
            result["jFromWrapBoundary"] = "skipped (no wrap)"
        }

        // Arrow keys act as h/j/k/l in normal mode (visual lines + sticky column).
        editorView.load(text: "first line\nsecond line\nthird")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        key("\u{F701}", keyCode: 125) // ↓ — pixel goal: lands on line 2 near col 2
        let afterDown = tv.selectedRange().location
        result["downArrowMovesDown"] = afterDown >= 11 && afterDown <= 15
        key("\u{F703}", keyCode: 124) // →
        result["rightArrowMovesRight"] = tv.selectedRange().location == afterDown + 1
        key("\u{F702}", keyCode: 123) // ←
        key("\u{F700}", keyCode: 126) // ↑
        result["arrowRoundTrip"] = tv.selectedRange().location == 2

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

    /// Real-vault image layouts: next to the note (markdown-relative) and in
    /// an arbitrary folder referenced by bare name (Obsidian attachments).
    private static func imageResolutionChecks(
        _ wc: MainWindowController,
        _ editorView: MarkdownEditorView
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        let root = wc.session.vault.rootURL
        let fm = FileManager.default

        func tinyPNG() -> Data? {
            let image = NSImage(size: NSSize(width: 4, height: 4))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: 4, height: 4).fill()
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
        guard let png = tinyPNG() else { return ["error": "no png"] }

        let sub = root.appendingPathComponent("ImgSub", isDirectory: true)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try? fm.createDirectory(at: media, withIntermediateDirectories: true)
        try? png.write(to: sub.appendingPathComponent("local.png"))
        try? png.write(to: media.appendingPathComponent("deep.png"))
        let note = sub.appendingPathComponent("imgnote.md")
        try? "![](local.png)\n\n![[deep.png]]\n".data(using: .utf8)?
            .write(to: note)
        wc.session.rescan()
        wc.open(noteAt: note) // sets the provider's noteFolderURL

        guard let provider = editorView.layoutController?.imageProvider else {
            return ["error": "no provider"]
        }
        provider.invalidate() // fresh filename index including the fixtures
        result["noteRelativeResolves"] = provider.resolveFileURL(forPath: "local.png") != nil
        result["vaultSearchResolves"] = provider.resolveFileURL(forPath: "deep.png") != nil
        result["noteRelativeRenders"] = provider.image(forPath: "local.png") != nil
        result["vaultSearchRenders"] = provider.image(forPath: "deep.png") != nil
        return result
    }

    /// Pane navigation + vim tree keys, all through real key events.
    private static func paneNavChecks(
        _ wc: MainWindowController,
        _ editorView: MarkdownEditorView,
        window: NSWindow
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        let tv = editorView.textView

        func keyTo(_ view: NSView, _ ch: String, keyCode: UInt16 = 0, control: Bool = false) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: control ? [.control] : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: ch, charactersIgnoringModifiers: ch,
                isARepeat: false, keyCode: keyCode
            ) else { return }
            view.keyDown(with: event)
        }
        func focusedOutline() -> NSOutlineView? {
            window.firstResponder as? NSOutlineView
        }

        window.makeFirstResponder(tv)
        keyTo(tv, "\u{1B}", keyCode: 53) // ensure normal mode (⌃h is insert-safe)
        // ⌃h from editor normal mode → tree focused.
        keyTo(tv, "h", control: true)
        guard let outline = focusedOutline() else {
            result["treeFocusedOnCtrlH"] = false
            return result
        }
        result["treeFocusedOnCtrlH"] = true

        // j/k move the cursor WITHOUT opening things.
        let titleBefore = window.title
        keyTo(outline, "j")
        keyTo(outline, "j")
        result["jMovesWithoutActivating"] = window.title == titleBefore
        let rowAfterJ = outline.selectedRow
        keyTo(outline, "k")
        result["kMovesBack"] = outline.selectedRow == rowAfterJ - 1

        // G then gg bounds.
        keyTo(outline, "G")
        result["GGoesLast"] = outline.selectedRow == outline.numberOfRows - 1
        keyTo(outline, "g")
        keyTo(outline, "g")
        result["ggGoesFirst"] = outline.selectedRow >= 0 && outline.selectedRow <= 1

        // Count multiplier: from the top, 3j hops three selectable rows
        // (the spacer row doesn't count).
        let start = outline.selectedRow
        keyTo(outline, "3")
        keyTo(outline, "j")
        var hops = 0
        var probe = start
        while hops < 3, probe < outline.numberOfRows - 1 {
            probe += 1
            if !(probe == 4) { hops += 1 } // row 4 is the spacer (after the Recent view row)
        }
        result["countJMultiplies"] = outline.selectedRow == probe
        keyTo(outline, "2")
        keyTo(outline, "k")
        result["countKMultiplies"] = outline.selectedRow < probe

        // Enter on a note row opens it and focuses the editor.
        keyTo(outline, "G") // last row = a note in the scratch vault
        keyTo(outline, "\r", keyCode: 36)
        result["enterOpensAndFocusesEditor"] = window.firstResponder === tv

        // ⌃h back to tree, ⌃l returns to editor.
        keyTo(tv, "h", control: true)
        let inTree = focusedOutline() != nil
        if let o = focusedOutline() { keyTo(o, "l", control: true) }
        result["ctrlLBackToEditor"] = inTree && window.firstResponder === tv

        // Tree visual mode: v anchors, k extends (files only), esc collapses
        // to the cursor but stays in the tree. Anchored at the BOTTOM — the
        // last rows are always root notes, regardless of how many saved-view
        // rows sit at the top.
        keyTo(tv, "h", control: true)
        if let outline = focusedOutline() {
            keyTo(outline, "G") // last row = a note
            keyTo(outline, "v")
            keyTo(outline, "k")
            result["visualSelectsTwo"] = outline.selectedRowIndexes.count == 2
            keyTo(outline, "k")
            result["visualExtendsThree"] = outline.selectedRowIndexes.count == 3
            keyTo(outline, "\u{1B}", keyCode: 53) // esc → collapse, stay in tree
            result["visualEscCollapses"] = outline.selectedRowIndexes.count == 1
                && window.firstResponder === outline
        }

        // Trash view stays live: with Trash visible, trashing a file from
        // elsewhere must appear without revisiting.
        keyTo(tv, "h", control: true)
        if let outline = focusedOutline(),
           let split = window.contentViewController as? NSSplitViewController,
           let sidebar = split.splitViewItems.first?.viewController as? SidebarViewController {
            _ = sidebar // (tree already focused)
            keyTo(outline, "g")
            keyTo(outline, "g")
            keyTo(outline, "2")
            keyTo(outline, "j") // Trash fixed row
            keyTo(outline, "\r", keyCode: 36) // open Trash view
            if let list = window.firstResponder as? NSTableView, !(list is NSOutlineView) {
                let rowsBefore = list.numberOfRows
                if let wc2 = window.windowController as? MainWindowController {
                    // Trash a real note from the session while Trash is visible.
                    if let victim = wc2.session.firstNote() {
                        wc2.session.trashNote(victim)
                    }
                }
                result["trashViewLiveRefresh"] = list.numberOfRows == rowsBefore + 1
            }
        }

        // Views (built-in Recent): Enter on the fixed row focuses its LIST;
        // j/k navigate; Enter opens a note; Esc stays in the list.
        keyTo(tv, "h", control: true)
        if let outline = focusedOutline() {
            keyTo(outline, "g")
            keyTo(outline, "g") // first row = Search
            keyTo(outline, "j") // Views
            keyTo(outline, "\r", keyCode: 36)
            let list = window.firstResponder as? NSTableView
            result["recentListFocused"] = list != nil && !(list is NSOutlineView)
            if let list {
                keyTo(list, "j")
                keyTo(list, "k")
                result["recentJKMoves"] = list.selectedRow == 0
                keyTo(list, "\u{1B}", keyCode: 53) // esc must NOT eject from the list
                result["escStaysInList"] = window.firstResponder === list
                keyTo(list, "h", control: true) // ⌃h is the way back to the tree
                result["ctrlHBackToTree"] = focusedOutline() != nil
                if let o = focusedOutline() {
                    keyTo(o, "\r", keyCode: 36) // selection still on Recent → reopen
                }
                if let list2 = window.firstResponder as? NSTableView, !(list2 is NSOutlineView) {
                    keyTo(list2, "\r", keyCode: 36) // open selected recent note
                    result["recentEnterOpensNote"] = window.firstResponder === tv
                }
            }
        }

        return result
    }

    /// Sidebar Views: row structure, opening the built-in Recent view through
    /// real key events, live NoQL filtering, saved-view round-trip, and the
    /// frontmatter-property query path.
    private static func viewsChecks(
        _ wc: MainWindowController,
        _ editorView: MarkdownEditorView,
        window: NSWindow
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        let tv = editorView.textView

        func keyTo(_ view: NSView, _ ch: String, keyCode: UInt16 = 0, control: Bool = false) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: control ? [.control] : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: ch, charactersIgnoringModifiers: ch,
                isARepeat: false, keyCode: keyCode
            ) else { return }
            view.keyDown(with: event)
        }
        func findViews<T: NSView>(_ type: T.Type) -> [T] {
            var found: [T] = []
            func walk(_ view: NSView) {
                if let v = view as? T { found.append(v) }
                view.subviews.forEach(walk)
            }
            if let content = window.contentView { walk(content) }
            return found
        }

        // Row structure: Search / Views / Trash / Recent(view) / spacer / tree…
        if let outline = findViews(NSOutlineView.self).first {
            result["viewsRowPresent"] = outline.numberOfRows >= 5
        }

        // Open Views via keys: tree → gg → j → Enter = built-in Recent list.
        window.makeFirstResponder(tv)
        keyTo(tv, "\u{1B}", keyCode: 53)
        keyTo(tv, "h", control: true)
        if let outline = window.firstResponder as? NSOutlineView {
            keyTo(outline, "g")
            keyTo(outline, "g")
            keyTo(outline, "j")
            keyTo(outline, "\r", keyCode: 36)
        }
        let list = window.firstResponder as? NSTableView
        result["builtinRecentOpens"] = list != nil && !(list is NSOutlineView)

        // The query field carries the built-in query and filters live.
        if let field = findViews(NSSearchField.self).first(where: { !$0.isHidden }) {
            result["builtinQueryPrefilled"] = field.stringValue == "sort:modified"
            field.stringValue = "sort:title limit:2"
            _ = field.sendAction(field.action, to: field.target)
            if let list {
                result["liveQueryFilters"] = list.numberOfRows <= 2 && list.numberOfRows > 0
            }
            field.stringValue = "sort:modified"
            _ = field.sendAction(field.action, to: field.target)
        }

        // Saved-view round-trip (store-level; alerts stay untested).
        wc.session.upsertView(name: "ProbeView", query: "tag:probetag")
        let viewsFile = wc.session.vault.rootURL
            .appendingPathComponent(".noiets/views.json")
        result["viewsFileWritten"] = FileManager.default.fileExists(atPath: viewsFile.path)
        result["savedViewListed"] = wc.session.savedViews.contains {
            $0.name == "ProbeView" && $0.query == "tag:probetag"
        }
        wc.session.deleteView(named: "ProbeView")
        result["savedViewDeleted"] = !wc.session.savedViews.contains { $0.name == "ProbeView" }

        // Frontmatter properties flow into the index and are queryable.
        if let index = wc.session.index {
            let extracted = NoteExtractor.extract(
                markdown: "---\nstatus: probe-done\n---\n# P\nbody",
                fallbackTitle: "P"
            )
            try? index.upsert(relPath: "SelfTestProp.md", extracted: extracted,
                              mtime: 1, size: 1, created: 1)
            let hits = (try? index.notes(matching: ViewQuery.parse("status:probe-done"))) ?? []
            result["propQueryHits"] = hits.count == 1 ? "PASS" : "FAIL: \(hits.count)"
            try? index.deleteNote(relPath: "SelfTestProp.md")
        }

        result["hiddenPathIgnored"] = Vault.hasHiddenComponent(".noiets/views.json")
            && Vault.hasHiddenComponent(".trash/x.md")
            && !Vault.hasHiddenComponent("Notes/x.md")

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
