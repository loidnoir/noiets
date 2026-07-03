import AppKit
import VimKit
import os

/// The Noiets editor text view. TextKit 2 only — a silent downgrade to
/// TextKit 1 (triggered by any `.layoutManager` access) would break live
/// preview and custom fragment rendering, so this class asserts TK2 at every
/// opportunity. Never reference `.layoutManager` anywhere in this app.
public final class NoietsTextView: NSTextView {
    private static let log = Logger(subsystem: "com.noiets", category: "editor")

    private(set) var theme: EditorTheme = .standard()

    /// The modal engine; keys route through it before AppKit sees them.
    public weak var vim: VimEngine?

    // Sticky visual column for j/k (see moveCaretVisually).
    var verticalGoalX: CGFloat?
    var inVerticalMove = false

    /// Builds a fully configured TextKit 2 editor view.
    public static func makeTextKit2(theme: EditorTheme) -> NoietsTextView {
        let tv = NoietsTextView(usingTextLayoutManager: true)
        precondition(tv.textLayoutManager != nil, "NoietsTextView must boot in TextKit 2 mode")
        tv.theme = theme
        tv.applyConfiguration()
        return tv
    }

    private func applyConfiguration() {
        allowsUndo = true
        isRichText = false
        importsGraphics = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true

        // Markdown is source text: every "smart" substitution corrupts it.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false

        drawsBackground = true
        backgroundColor = theme.background
        insertionPointColor = theme.accentColor
        // No underlines on links — accent color + hand cursor only.
        linkTextAttributes = [
            .foregroundColor: theme.accentColor,
            .cursor: NSCursor.pointingHand,
        ]
        typingAttributes = theme.typingAttributes()
        defaultParagraphStyle = theme.defaultParagraphStyle
        textContainerInset = NSSize(width: 28, height: 28)
    }

    // MARK: Vim routing

    /// The wiki-link completion popup gets first look at navigation keys.
    public weak var completionInterceptor: WikiLinkAutocomplete?

    /// Focus transitions re-assert the vim caret shape (the insertion
    /// indicator is created/reset around first-responder changes).
    public var onFocusChange: (() -> Void)?

    /// ⌃h/⌃j/⌃k/⌃l pane navigation (normal/visual mode only — insert keeps
    /// the control keys for the system/IME).
    public var onPaneNavigate: ((Character) -> Void)?

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.onFocusChange?() } }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.onFocusChange?() } }
        return result
    }

    public override func keyDown(with event: NSEvent) {
        if let completionInterceptor, completionInterceptor.handleKeyDown(event) {
            return
        }
        // Pane navigation gets first look at ⌃h/j/k/l outside insert mode.
        if let onPaneNavigate, let vim, vim.mode != .insert,
           event.modifierFlags.contains(.control),
           let ch = event.charactersIgnoringModifiers?.first,
           "hjkl".contains(ch) {
            onPaneNavigate(ch)
            return
        }
        if let vim, vim.handleKey(VimKey(event: event)) {
            return // consumed by the modal engine
        }
        super.keyDown(with: event) // → interpretKeyEvents → IME-safe insertion
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if let s = string as? String {
            vim?.recordInsertedText(s)
        } else if let a = string as? NSAttributedString {
            vim?.recordInsertedText(a.string)
        }
    }

    public override func deleteBackward(_ sender: Any?) {
        super.deleteBackward(sender)
        vim?.recordBackspace()
    }

    // MARK: TK2 tripwire

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, textLayoutManager == nil {
            Self.log.fault("TextKit 2 downgrade detected — NoietsTextView fell back to TextKit 1")
            assertionFailure("TextKit 2 downgrade detected")
        }
    }

    // MARK: Centered column

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let horizontal = max(28, (newSize.width - theme.maxColumnWidth) / 2)
        if abs(textContainerInset.width - horizontal) > 0.5 {
            textContainerInset = NSSize(width: horizontal, height: textContainerInset.height)
        }
    }
}

// MARK: - VimTextTarget

extension NoietsTextView: VimTextTarget {
    public var text: NSString { string as NSString }

    public var selection: NSRange {
        get { selectedRange() }
        set {
            // Downstream affinity = the caret belongs to the character AFTER
            // the index (vim block semantics). Without it, an index landing
            // exactly on a soft-wrap boundary reads as "end of the row above"
            // and the next j moves to the row the caret already shows.
            setSelectedRange(newValue, affinity: .downstream, stillSelecting: false)
        }
    }

    /// Vim edits flow through the standard change pipeline so undo, the
    /// highlighter, live preview, and autosave all fire exactly as for typing.
    public func replace(_ range: NSRange, with string: String) {
        guard shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
    }

    public func beginUndoGroup() {
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
    }

    public func endUndoGroup() {
        undoManager?.endUndoGrouping()
    }

    public func performUndo() {
        undoManager?.undo()
    }

    public func performRedo() {
        undoManager?.redo()
    }

    public func scrollCaretToVisible() {
        scrollRangeToVisible(selectedRange())
    }

    public func visibleLineCount() -> Int {
        let lineHeight = theme.baseFont.boundingRectForFont.height + theme.lineSpacing
        return max(1, Int(visibleRect.height / max(lineHeight, 1)))
    }

    /// Visual-line movement with a sticky pixel goal column: the caret's x is
    /// remembered across the whole j/k sequence — shorter lines clamp to
    /// their end WITHOUT overwriting the memory, so a later longer line
    /// restores the original position. The goal resets whenever the caret
    /// moves by any other means (h/l/w, clicks, typing, motions).
    public func moveCaretVisually(lines: Int) {
        inVerticalMove = true
        defer { inVerticalMove = false }

        let goal = verticalGoalX ?? caretViewRect()?.minX
        verticalGoalX = goal

        for _ in 0..<abs(lines) {
            if lines > 0 {
                moveDown(nil)
            } else {
                moveUp(nil)
            }
        }

        // Land on the destination visual line at the remembered x. The result
        // is clamped to the logical line moveDown/moveUp actually reached:
        // on an empty (or short) line a far-out x has no glyphs, and the hit
        // test can otherwise escape to a neighboring line.
        if let goal, let lineRect = caretViewRect() {
            let ns = string as NSString
            guard ns.length > 0 else { return }
            let landed = min(selectedRange().location, ns.length - 1)
            let lineRange = ns.lineRange(for: NSRange(location: landed, length: 0))
            var contentEnd = lineRange.location + lineRange.length
            if contentEnd > lineRange.location,
               ns.character(at: contentEnd - 1) == 0x0A {
                contentEnd -= 1
            }
            let index = characterIndexForInsertion(at: NSPoint(x: goal, y: lineRect.midY))
            var clamped = min(max(index, lineRange.location), contentEnd)

            // Wrap-boundary guard: a far-x hit on a wrapped row can return the
            // boundary index, whose character belongs to the NEXT visual row.
            // If the char under the caret isn't on the destination row, step
            // back onto it.
            if clamped < ns.length, let window {
                let charScreen = firstRect(
                    forCharacterRange: NSRange(location: clamped, length: 1), actualRange: nil
                )
                if charScreen != .zero {
                    let charRect = convert(window.convertFromScreen(charScreen), from: nil)
                    if abs(charRect.midY - lineRect.midY) > lineRect.height / 2 {
                        clamped = max(lineRange.location, clamped - 1)
                    }
                }
            }
            setSelectedRange(NSRange(location: clamped, length: 0),
                             affinity: .downstream, stillSelecting: false)
        }
    }

    /// Every selection change funnels through here — anything that isn't our
    /// own vertical movement invalidates the sticky column.
    public override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        if !inVerticalMove {
            verticalGoalX = nil
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// Every rendered (visual) row: character location + rect in view
    /// coordinates. Wrapped rows count individually — this is what the
    /// : gutter numbers and what :N jumps to, consistent with visual j/k.
    /// Forces full layout; used only for deliberate, transient actions.
    public func visualRows() -> [(location: Int, rect: CGRect)] {
        guard let layoutManager = textLayoutManager,
              let contentStorage = textContentStorage else { return [] }
        var rows: [(Int, CGRect)] = []
        let docStart = layoutManager.documentRange.location
        layoutManager.enumerateTextLayoutFragments(
            from: docStart,
            options: [.ensuresLayout]
        ) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            let fragmentStart = contentStorage.offset(
                from: docStart, to: fragment.rangeInElement.location
            )
            for line in fragment.textLineFragments {
                let rect = line.typographicBounds
                    .offsetBy(dx: origin.x + self.textContainerInset.width,
                              dy: origin.y + self.textContainerInset.height)
                rows.append((fragmentStart + line.characterRange.location, rect))
            }
            return true
        }
        return rows
    }

    /// Character location for a 1-based visual row (clamped to the last row).
    /// Rows that start a logical line land on their first non-blank, vim-style.
    public func characterLocation(ofVisualRow row: Int) -> Int? {
        let rows = visualRows()
        guard !rows.isEmpty else { return nil }
        let location = rows[min(max(row, 1), rows.count) - 1].location
        let ns = string as NSString
        guard ns.length > 0 else { return 0 }
        if Motions.lineStart(ns, at: min(location, ns.length - 1)) == location {
            return Motions.firstNonBlank(ns, at: location)
        }
        return location
    }

    /// Caret rect in view coordinates.
    private func caretViewRect() -> NSRect? {
        guard let window else { return nil }
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        guard screenRect != .zero else { return nil }
        return convert(window.convertFromScreen(screenRect), from: nil)
    }
}

// MARK: - NSEvent → VimKey

public extension VimKey {
    @MainActor
    init(event: NSEvent) {
        self.init(
            characters: event.charactersIgnoringModifiers ?? "",
            isEscape: event.keyCode == 53,
            isReturn: event.keyCode == 36 || event.keyCode == 76
                || event.characters == "\r" || event.characters == "\n",
            isBackspace: event.keyCode == 51,
            hasCommand: event.modifierFlags.contains(.command),
            hasControl: event.modifierFlags.contains(.control),
            hasOption: event.modifierFlags.contains(.option)
        )
    }
}
