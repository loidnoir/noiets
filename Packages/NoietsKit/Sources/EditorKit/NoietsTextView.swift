import AppKit
import os

/// The Noiets editor text view. TextKit 2 only — a silent downgrade to
/// TextKit 1 (triggered by any `.layoutManager` access) would break live
/// preview and custom fragment rendering, so this class asserts TK2 at every
/// opportunity. Never reference `.layoutManager` anywhere in this app.
public final class NoietsTextView: NSTextView {
    private static let log = Logger(subsystem: "com.noiets", category: "editor")

    private(set) var theme: EditorTheme = .standard()

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
        typingAttributes = theme.typingAttributes()
        defaultParagraphStyle = theme.defaultParagraphStyle
        textContainerInset = NSSize(width: 28, height: 28)
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
