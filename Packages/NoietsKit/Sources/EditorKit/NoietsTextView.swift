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

    public override func keyDown(with event: NSEvent) {
        if let completionInterceptor, completionInterceptor.handleKeyDown(event) {
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
        set { setSelectedRange(newValue) }
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
