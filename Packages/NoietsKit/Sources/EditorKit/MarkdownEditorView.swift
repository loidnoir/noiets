import AppKit
import VimKit

/// The complete markdown editing surface: scroll view + TextKit 2 text view,
/// highlighter/live-preview, and the vim engine with its mode indicator. The
/// app shell embeds this and stays out of editor internals.
public final class MarkdownEditorView: NSView {
    public let theme: EditorTheme
    public let textView: NoietsTextView
    public let scrollView = NSScrollView()
    public let highlighter: IncrementalHighlighter
    public private(set) var layoutController: LivePreviewLayoutController?
    public let vim = VimEngine()

    /// Forwarded vim callbacks (the engine's own slots are used internally
    /// for caret shape management).
    public var onVimModeChange: ((VimMode) -> Void)?
    public var onVimStatus: ((String) -> Void)?

    /// Root for resolving relative image paths (the vault folder).
    public var resourceRoot: URL? {
        didSet { layoutController?.imageProvider.rootURL = resourceRoot }
    }

    /// Block caret drawn in normal/visual mode (insert uses the native
    /// blinking bar).
    private let blockCaret = CaretBlockView()

    /// Transient : mode gutter.
    private var lineNumberGutter: LineNumberGutter?

    /// Test/diagnostic hook.
    public var isLineNumberGutterActive: Bool { lineNumberGutter != nil }

    private func setLineNumbersVisible(_ visible: Bool) {
        if visible {
            guard lineNumberGutter == nil else { return }
            let gutter = LineNumberGutter(textView: textView, theme: theme)
            textView.addSubview(gutter)
            lineNumberGutter = gutter
        } else {
            lineNumberGutter?.removeFromSuperview()
            lineNumberGutter = nil
        }
    }

    /// Fired on every text change (typing, paste, vim edit). Used for autosave.
    public var onTextChange: (() -> Void)?

    /// Wiki-link navigation: [[target]] clicked (target string, un-encoded).
    public var onOpenWikiLink: ((String) -> Void)?
    /// #tag clicked.
    public var onOpenTag: ((String) -> Void)?
    /// Titles/stems for [[ autocompletion, filtered by the partial query.
    public var wikiCompletionProvider: ((String) -> [String])?

    let autocomplete = WikiLinkAutocomplete()

    /// Test/diagnostic hook: is the [[ completion popup showing?
    public var isWikiCompletionActive: Bool { autocomplete.isActive }

    public init(theme: EditorTheme = .standard()) {
        self.theme = theme
        self.textView = NoietsTextView.makeTextKit2(theme: theme)
        self.highlighter = IncrementalHighlighter(theme: theme)
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        scrollView.automaticallyAdjustsContentInsets = true

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.textStorage?.delegate = highlighter
        highlighter.textView = textView

        let controller = LivePreviewLayoutController(
            theme: theme,
            highlighter: highlighter,
            contentStorage: textView.textContentStorage
        )
        layoutController = controller
        textView.textLayoutManager?.delegate = controller

        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        setupVim()
    }

    // MARK: Vim

    private func setupVim() {
        vim.target = textView
        textView.vim = vim
        textView.completionInterceptor = autocomplete

        blockCaret.color = theme.accentColor.withAlphaComponent(0.38)
        blockCaret.wantsLayer = true
        blockCaret.layer?.cornerRadius = 1.5
        blockCaret.isHidden = true
        textView.addSubview(blockCaret) // scrolls with the text

        textView.onFocusChange = { [weak self] in
            self?.refreshCaretShape()
        }
        vim.onCommandMode = { [weak self] active in
            self?.setLineNumbersVisible(active)
        }
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(textGeometryChanged(_:)),
            name: NSView.frameDidChangeNotification, object: textView
        )
        vim.onModeChange = { [weak self] mode in
            self?.refreshCaretShape()
            self?.onVimModeChange?(mode)
        }
        vim.onStatus = { [weak self] status in
            self?.onVimStatus?(status)
        }
        refreshCaretShape()
    }

    // MARK: Caret shape
    // insert → native blinking bar; normal → blinking block; visual → steady block.

    private var blinkTimer: Timer?

    func refreshCaretShape() {
        if vim.mode == .insert {
            stopBlink()
            blockCaret.isHidden = true
            setNativeCaretVisible(true)
            return
        }
        setNativeCaretVisible(false)
        placeBlockCaret()
        blockCaret.alphaValue = 1 // solid immediately after any movement…

        if vim.mode == .normal {
            startBlink() // …then blink while idle in normal mode
        } else {
            stopBlink() // steady block in visual
        }

        // Crossing block boundaries (fences, tables) restyles paragraphs and
        // shifts line heights — TextKit 2 finishes that layout after this
        // delegate returns, which would strand the block at pre-layout
        // coordinates. Re-place once the pass settles.
        DispatchQueue.main.async { [weak self] in
            self?.placeBlockCaret()
        }
    }

    /// Positions the block over the current display caret (no blink changes).
    private func placeBlockCaret() {
        guard vim.mode != .insert else { return }
        // The overlay can be dropped by view churn — re-assert attachment.
        if blockCaret.superview !== textView {
            textView.addSubview(blockCaret)
        }
        guard let rect = caretGlyphRect(at: vim.displayCaret) else {
            blockCaret.isHidden = true
            return
        }
        blockCaret.frame = rect
        blockCaret.isHidden = false
    }

    /// Any geometry change (document height shifts from live-preview restyles,
    /// wrapping, window resize) re-places the block.
    @objc private func textGeometryChanged(_ note: Notification) {
        placeBlockCaret()
    }

    /// macOS 14+ draws the caret with NSTextInsertionIndicator (nested
    /// somewhere in the text view's subtree), which ignores a transparent
    /// insertionPointColor — its displayMode is the real switch.
    private func setNativeCaretVisible(_ visible: Bool) {
        textView.insertionPointColor = visible ? theme.accentColor : .clear
        for indicator in Self.insertionIndicators(in: textView) {
            indicator.displayMode = visible ? .automatic : .hidden
        }
    }

    private static func insertionIndicators(in view: NSView) -> [NSTextInsertionIndicator] {
        var found: [NSTextInsertionIndicator] = []
        for sub in view.subviews {
            if let indicator = sub as? NSTextInsertionIndicator {
                found.append(indicator)
            }
            found.append(contentsOf: insertionIndicators(in: sub))
        }
        return found
    }

    /// Diagnostics for the self-test.
    public var caretDebugInfo: [String: Any] {
        let indicators = Self.insertionIndicators(in: textView)
        return [
            "blockVisible": !blockCaret.isHidden,
            "blockFrame": NSStringFromRect(blockCaret.frame),
            "blockAttached": blockCaret.superview === textView,
            "indicatorsFound": indicators.count,
            "indicatorsHidden": indicators.allSatisfy { $0.displayMode == .hidden },
        ]
    }

    private func startBlink() {
        stopBlink()
        let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.blockCaret.isHidden else { return }
                self.blockCaret.alphaValue = self.blockCaret.alphaValue < 0.5 ? 1 : 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blockCaret.alphaValue = 1
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            refreshCaretShape() // first placement needs screen-coordinate space
        } else {
            stopBlink()
        }
    }

    /// Rect of the character cell under the caret, in text-view coordinates.
    private func caretGlyphRect(at location: Int) -> NSRect? {
        guard let window = textView.window else { return nil }
        let length = (textView.string as NSString).length
        let clamped = min(max(location, 0), length)
        let range = NSRange(location: clamped, length: clamped < length ? 1 : 0)
        var screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        if screenRect == .zero { return nil }
        let fallbackWidth = theme.baseFontSize * 0.55
        if screenRect.width < 2 || screenRect.width > theme.baseFontSize * 2.5 {
            screenRect.size.width = fallbackWidth // newline / EOF / wide glyphs
        }
        let windowRect = window.convertFromScreen(screenRect)
        return textView.convert(windowRect, from: nil)
    }

    // MARK: Content

    public var string: String { textView.string }

    /// Replaces the buffer with a freshly loaded note (resets undo history).
    public func load(text: String) {
        autocomplete.hide()
        vim.reset()
        textView.string = text // triggers didProcessEditing → full style pass
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // Defer past TextKit 2's initial viewport height estimation — an
        // immediate scroll drifts once the estimate settles.
        DispatchQueue.main.async { [weak self] in
            self?.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    public func focus() {
        window?.makeFirstResponder(textView)
    }
}

/// Appearance-aware solid block for the vim caret.
final class CaretBlockView: NSView {
    var color: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }
}

extension MarkdownEditorView: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        onTextChange?()
        refreshWikiAutocomplete()
        refreshCaretShape()
        lineNumberGutter?.recomputeLines()
    }

    // MARK: Link routing

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let urlString = (link as? String) ?? (link as? URL)?.absoluteString,
              let url = URL(string: urlString) else { return false }
        if url.scheme == "noiets" {
            let value = url.path.dropFirst().removingPercentEncoding ?? String(url.path.dropFirst())
            switch url.host {
            case "open":
                onOpenWikiLink?(value)
            case "tag":
                onOpenTag?(value)
            default:
                break
            }
            return true
        }
        return false // http(s) etc → system default handling
    }

    // MARK: [[ autocompletion

    /// Detects an unclosed "[[query" immediately before the caret.
    private func wikiQueryContext() -> (query: String, queryRange: NSRange)? {
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret <= text.length, textView.selectedRange().length == 0 else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: min(caret, max(0, text.length - 1)), length: 0)).location
        var i = caret - 1
        while i >= lineStart {
            let c = text.character(at: i)
            if c == unichar(UInt8(ascii: "]")) { return nil }
            if c == unichar(UInt8(ascii: "[")) {
                guard i > lineStart, text.character(at: i - 1) == unichar(UInt8(ascii: "[")) else { return nil }
                let queryStart = i + 1
                let query = text.substring(with: NSRange(location: queryStart, length: caret - queryStart))
                if query.contains("|") || query.contains("#") { return nil }
                return (query, NSRange(location: queryStart, length: caret - queryStart))
            }
            i -= 1
        }
        return nil
    }

    private func refreshWikiAutocomplete() {
        guard let window = textView.window,
              let provider = wikiCompletionProvider,
              let context = wikiQueryContext() else {
            autocomplete.hide()
            return
        }
        let suggestions = provider(context.query)
        guard !suggestions.isEmpty else {
            autocomplete.hide()
            return
        }
        let caretRect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        autocomplete.show(suggestions: suggestions, at: caretRect, parent: window) { [weak self] picked in
            self?.insertWikiCompletion(picked)
        }
    }

    private func insertWikiCompletion(_ target: String) {
        guard let context = wikiQueryContext() else { return }
        let text = textView.string as NSString
        // Replace the partial query (and consume an existing "]]" right after
        // the caret if the tokenizer auto-close ever adds one).
        var replaceRange = context.queryRange
        var insert = target
        let after = replaceRange.location + replaceRange.length
        if after + 2 <= text.length, text.substring(with: NSRange(location: after, length: 2)) == "]]" {
            // keep the existing closer
        } else {
            insert += "]]"
        }
        if textView.shouldChangeText(in: replaceRange, replacementString: insert) {
            textView.textStorage?.replaceCharacters(in: replaceRange, with: insert)
            textView.didChangeText()
            let newCaret = replaceRange.location + (insert as NSString).length
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        }
        autocomplete.hide()
    }

    // MARK: Live Preview — active paragraph tracking

    public func textViewDidChangeSelection(_ notification: Notification) {
        if autocomplete.isActive, wikiQueryContext() == nil {
            autocomplete.hide()
        }
        guard let storage = textView.textStorage else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound else { return }
        let paragraph = text.length == 0
            ? NSRange(location: 0, length: 0)
            : text.paragraphRange(for: NSRange(
                location: min(selection.location, text.length),
                length: min(selection.length, max(0, text.length - selection.location))
              ))
        highlighter.updateActiveParagraph(storage, to: paragraph)
        refreshCaretShape()
    }

    // MARK: Live Preview — caret skips collapsed markup

    public func textView(
        _ textView: NSTextView,
        willChangeSelectionFromCharacterRange oldRange: NSRange,
        toCharacterRange newRange: NSRange
    ) -> NSRange {
        guard newRange.length == 0, let storage = textView.textStorage,
              storage.length > 0 else { return newRange }

        let forward = newRange.location >= oldRange.location + oldRange.length
        var location = min(newRange.location, storage.length)

        if forward {
            // Never land in front of (or inside) an invisible run going right.
            while location < storage.length, hiddenRun(at: location, in: storage) != nil {
                guard let run = hiddenRun(at: location, in: storage) else { break }
                location = run.location + run.length
            }
        } else {
            while location > 0, let run = hiddenRun(at: location - 1, in: storage) {
                location = run.location
            }
        }
        return NSRange(location: location, length: 0)
    }

    private func hiddenRun(at index: Int, in storage: NSTextStorage) -> NSRange? {
        guard index >= 0, index < storage.length else { return nil }
        var effective = NSRange(location: 0, length: 0)
        let value = storage.attribute(
            .noietsHidden, at: index,
            longestEffectiveRange: &effective,
            in: NSRange(location: 0, length: storage.length)
        )
        return value == nil ? nil : effective
    }
}
