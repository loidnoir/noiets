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
        guard ProcessInfo.processInfo.environment["NOIETS_SELFTEST"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
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
}
