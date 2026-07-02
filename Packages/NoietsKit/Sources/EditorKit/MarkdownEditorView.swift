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

    /// Root for resolving relative image paths (the vault folder).
    public var resourceRoot: URL? {
        didSet { layoutController?.imageProvider.rootURL = resourceRoot }
    }

    private let modePill = NSTextField(labelWithString: "")

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

        modePill.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        modePill.textColor = theme.mutedColor
        modePill.alignment = .center
        modePill.wantsLayer = true
        modePill.layer?.cornerRadius = 4
        modePill.layer?.backgroundColor = theme.codeBackground.cgColor
        modePill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modePill)
        NSLayoutConstraint.activate([
            modePill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            modePill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            modePill.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            modePill.heightAnchor.constraint(equalToConstant: 18),
        ])

        vim.onModeChange = { [weak self] mode in
            self?.refreshPill(mode: mode, status: nil)
        }
        vim.onStatus = { [weak self] status in
            self?.refreshPill(mode: nil, status: status)
        }
        refreshPill(mode: vim.mode, status: "")
    }

    private var lastStatus = ""

    private func refreshPill(mode: VimMode?, status: String?) {
        if let status { lastStatus = status }
        let m = mode ?? vim.mode
        let text = lastStatus.isEmpty ? m.label : "\(m.label)  \(lastStatus)"
        modePill.stringValue = "  \(text)  "
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

extension MarkdownEditorView: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        onTextChange?()
        refreshWikiAutocomplete()
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
