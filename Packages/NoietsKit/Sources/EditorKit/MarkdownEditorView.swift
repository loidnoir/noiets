import AppKit
import RenderKit
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

    /// Folder of the open note — markdown-relative image paths resolve here.
    public var noteFolderURL: URL? {
        didSet { layoutController?.imageProvider.noteFolderURL = noteFolderURL }
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

    /// Local file opens from clicks (image embeds, file links). When unset,
    /// files open with the system default app.
    public var onOpenImageFile: ((URL) -> Void)?
    /// Titles/stems for [[ autocompletion, filtered by the partial query.
    public var wikiCompletionProvider: ((String) -> [String])?
    /// Tag names for # autocompletion, filtered by the partial query
    /// (empty query = bare `#` — the provider decides what to surface).
    public var tagCompletionProvider: ((String) -> [String])?

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

        // Remote images render as soon as their download lands.
        controller.imageProvider.onRemoteImageLoaded = { [weak self] in
            guard let layoutManager = self?.textView.textLayoutManager else { return }
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
        }
        // …and so do async mermaid diagram renders.
        NotificationCenter.default.addObserver(
            self, selector: #selector(mermaidDidRender(_:)),
            name: .mermaidDidRender, object: nil
        )
        textView.onPasteImage = { [weak self] in
            self?.pasteImageFromClipboard() ?? false
        }
        textView.onDoubleClick = { [weak self] index in
            self?.openImageIfPresent(onLineAt: index) ?? false
        }
        // Single click zooms a *rendered* image; when the caret is already
        // on that line the source is revealed and clicks edit it instead.
        textView.onImageLineClick = { [weak self] index in
            guard let self else { return false }
            let text = self.textView.string as NSString
            guard text.length > 0 else { return false }
            let clicked = text.lineRange(for: NSRange(location: min(index, text.length - 1), length: 0))
            let caret = self.textView.selectedRange().location
            let active = text.lineRange(for: NSRange(location: min(caret, text.length), length: 0))
            guard clicked != active else { return false }
            return self.openImageIfPresent(onLineAt: index)
        }

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
        vim.onYank = { text in
            // Yanks and deletes mirror to the system clipboard, so vim y/d/x
            // and ⌘V in other apps compose.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        vim.pasteboardText = {
            // …and p/P read it back, so copies made in other apps paste too.
            NSPasteboard.general.string(forType: .string)
        }
        refreshCaretShape()
    }

    // MARK: Caret shape
    // insert → native blinking bar; normal → blinking block; visual → steady block.

    private var blinkTimer: Timer?

    func refreshCaretShape() {
        // No caret decoration when the editor doesn't have focus (the tree
        // pane owns the keyboard) — doubles as the focus indicator.
        if let responder = textView.window?.firstResponder, responder !== textView {
            stopBlink()
            blockCaret.isHidden = true
            return
        }
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
        let caret = vim.displayCaret
        guard let rect = caretGlyphRect(at: caret) else {
            blockCaret.isHidden = true
            smearCaretLocation = caret
            return
        }
        // Trail only on real cursor motion — the caret offset changing — not
        // on relayout re-placements (geometry shifts, block restyles).
        if caret != smearCaretLocation, !blockCaret.isHidden {
            spawnCaretSmear(from: blockCaret.frame, to: rect)
        }
        smearCaretLocation = caret
        blockCaret.frame = rect
        blockCaret.isHidden = false
    }

    // MARK: Caret smear
    // Vim-style motion trail: on every jump a quad stretched between the old
    // and new caret cells collapses into the new cell while fading — the
    // cursor visibly "travels" instead of teleporting.

    private var smearCaretLocation = -1

    private func spawnCaretSmear(from old: NSRect, to new: NSRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let dx = new.midX - old.midX
        let dy = new.midY - old.midY
        guard abs(dx) + abs(dy) >= 2 else { return }  // sub-cell jitter
        textView.wantsLayer = true
        guard let host = textView.layer else { return }

        let (start, end) = smearQuads(from: old, to: new, dx: dx, dy: dy)
        let smear = CAShapeLayer()
        smear.fillColor = blockCaret.color.cgColor
        smear.path = end
        smear.opacity = 0
        host.addSublayer(smear)

        let collapse = CABasicAnimation(keyPath: "path")
        collapse.fromValue = start
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        let group = CAAnimationGroup()
        group.animations = [collapse, fade]
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        smear.add(group, forKey: "smear")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            smear.removeFromSuperlayer()
        }
    }

    /// The smear quad's leading edge sits on the new cell, its trailing edge
    /// on the far side of the old cell; the end state is the new cell itself,
    /// so the path animation sweeps the tail in behind the cursor.
    private func smearQuads(
        from old: NSRect, to new: NSRect, dx: CGFloat, dy: CGFloat
    ) -> (start: CGPath, end: CGPath) {
        // Corner order tl → tr → br → bl in the text view's flipped coords.
        func corners(_ r: NSRect) -> [CGPoint] {
            [
                CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
            ]
        }
        let o = corners(old)
        let n = corners(new)
        let start: [CGPoint]
        if abs(dx) >= abs(dy) {
            start = dx >= 0 ? [o[0], n[1], n[2], o[3]] : [n[0], o[1], o[2], n[3]]
        } else {
            start = dy >= 0 ? [o[0], o[1], n[2], n[3]] : [n[0], n[1], o[2], o[3]]
        }
        func path(_ points: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: points)
            p.closeSubpath()
            return p
        }
        return (path(start), path(n))
    }

    /// Any geometry change (document height shifts from live-preview restyles,
    /// wrapping, window resize) re-places the block.
    @objc private func textGeometryChanged(_ note: Notification) {
        placeBlockCaret()
        refreshMermaidOverlays()
    }

    @objc private func mermaidDidRender(_ note: Notification) {
        guard let layoutManager = textView.textLayoutManager else { return }
        layoutManager.invalidateLayout(for: layoutManager.documentRange)
        // Fragment frames settle after the invalidation's layout pass.
        DispatchQueue.main.async { [weak self] in
            self?.refreshMermaidOverlays()
        }
    }

    // MARK: Mermaid canvas overlays
    // Rendered diagrams are interactive (pan/zoom) — fragments only reserve
    // the area; a real view per visible block sits on top and scrolls with
    // the text. Re-synced on any event that can move or invalidate blocks.

    private var mermaidOverlays: [MermaidCanvasView] = []

    /// Test/diagnostic hook.
    public var mermaidOverlayCount: Int { mermaidOverlays.count }

    public func refreshMermaidOverlays() {
        guard let controller = layoutController,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = textView.textContentStorage else { return }
        let blocks = controller.mermaidDisplayBlocks()

        while mermaidOverlays.count > blocks.count {
            mermaidOverlays.removeLast().removeFromSuperview()
        }
        while mermaidOverlays.count < blocks.count {
            let overlay = MermaidCanvasView(theme: theme)
            textView.addSubview(overlay)
            mermaidOverlays.append(overlay)
        }

        for (overlay, block) in zip(mermaidOverlays, blocks) {
            overlay.setImage(block.image, sourceKey: block.source)
            overlay.onEdit = { [weak self] in
                guard let self else { return }
                self.textView.setSelectedRange(NSRange(location: block.fenceContentEnd, length: 0))
                self.window?.makeFirstResponder(self.textView)
            }
            let start = contentStorage.documentRange.location
            guard let location = contentStorage.location(start, offsetBy: block.fenceLocation),
                  let fragment = layoutManager.textLayoutFragment(for: location) else {
                overlay.frame = .zero
                continue
            }
            let pad = textView.textContainer?.lineFragmentPadding ?? 5
            let width = textView.textContainer?.size.width ?? textView.bounds.width
            let origin = textView.textContainerOrigin
            let area = fragment.layoutFragmentFrame
            overlay.frame = CGRect(x: origin.x + pad,
                                   y: origin.y + area.minY + 8,
                                   width: width - pad * 2,
                                   height: max(area.height - 16, 0))
        }
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

    // MARK: Image paste

    /// ⌘V with an image (or image file) on the clipboard: save it into the
    /// vault's assets/ folder and insert the markdown embed at the caret.
    private static let pastableImageExts: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
    private static let pastableVideoExts: Set<String> =
        ["mp4", "mov", "m4v", "webm", "avi", "mkv"]

    private func pasteImageFromClipboard() -> Bool {
        guard let root = resourceRoot else { return false }
        let pasteboard = NSPasteboard.general

        // A media FILE on the clipboard (Finder copy) — image, gif, or video
        // — is copied into the vault's hidden .cache/ folder and referenced.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let file = urls.first {
            let ext = file.pathExtension.lowercased()
            guard Self.pastableImageExts.contains(ext) || Self.pastableVideoExts.contains(ext),
                  let dest = cacheDestination(ext: ext, root: root),
                  (try? FileManager.default.copyItem(at: file, to: dest)) != nil
            else { return false }
            insertMediaReference(name: dest.lastPathComponent)
            return true
        }

        // Raw image data (screenshot in clipboard) is written as PNG.
        if let image = NSImage(pasteboard: pasteboard) {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]),
                  let dest = cacheDestination(ext: "png", root: root),
                  (try? png.write(to: dest)) != nil
            else { return false }
            insertMediaReference(name: dest.lastPathComponent)
            return true
        }
        return false
    }

    /// A unique pasted-<timestamp> destination inside `<vault>/.cache`
    /// (dot-prefixed: hidden from the tree and never indexed as a note).
    private func cacheDestination(ext: String, root: URL) -> URL? {
        let cache = root.appendingPathComponent(".cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var name = "pasted-\(formatter.string(from: Date())).\(ext)"
        var counter = 2
        while FileManager.default.fileExists(atPath: cache.appendingPathComponent(name).path) {
            name = "pasted-\(formatter.string(from: Date()))-\(counter).\(ext)"
            counter += 1
        }
        return cache.appendingPathComponent(name)
    }

    private func insertMediaReference(name: String) {
        let markdown = "![](.cache/\(name))"
        let caret = textView.selectedRange()
        if textView.shouldChangeText(in: caret, replacementString: markdown) {
            textView.textStorage?.replaceCharacters(in: caret, with: markdown)
            textView.didChangeText()
            textView.setSelectedRange(
                NSRange(location: caret.location + (markdown as NSString).length, length: 0)
            )
        }
    }

    // MARK: Content

    public var string: String { textView.string }

    /// Replaces the buffer with a freshly loaded note (resets undo history).
    /// Locked documents: fully rendered (the caret's line never reverts to
    /// raw source) and immutable (every change rejected at the text gate).
    public func setLocked(_ locked: Bool) {
        guard highlighter.alwaysPreview != locked || textView.isReadOnlyDocument != locked else {
            return
        }
        textView.isReadOnlyDocument = locked
        highlighter.alwaysPreview = locked
        if let storage = textView.textStorage {
            highlighter.restyleAll(storage)
            if !locked {
                // Unlocking: re-establish the caret's paragraph as active so
                // it reverts to raw source without requiring a caret move.
                let text = textView.string as NSString
                let selection = textView.selectedRange()
                if selection.location != NSNotFound, text.length > 0 {
                    let paragraph = text.paragraphRange(for: NSRange(
                        location: min(selection.location, text.length),
                        length: min(selection.length, max(0, text.length - selection.location))
                    ))
                    highlighter.updateActiveParagraph(storage, to: paragraph)
                }
            }
        }
        if let layoutManager = textView.textLayoutManager {
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
        }
        refreshMermaidOverlays()
    }

    public func load(text: String) {
        autocomplete.hide()
        vim.reset()
        mermaidOverlays.forEach { $0.removeFromSuperview() }
        mermaidOverlays.removeAll()
        textView.string = text // triggers didProcessEditing → full style pass
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // Defer past TextKit 2's initial viewport height estimation — an
        // immediate scroll drifts once the estimate settles (and lets the
        // first layout pass place any mermaid canvases).
        DispatchQueue.main.async { [weak self] in
            self?.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            self?.refreshMermaidOverlays()
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
        refreshAutocomplete()
        refreshCaretShape()
        refreshMermaidOverlays()
        lineNumberGutter?.recomputeLines()
    }

    // MARK: Link routing

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let urlString = (link as? String) ?? (link as? URL)?.absoluteString else { return false }
        if let url = URL(string: urlString), url.scheme == "noiets" {
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
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }
        // Anything else is a vault-relative file reference (image paths,
        // ![](assets/x.png) …): resolve it and open it.
        if let file = layoutController?.imageProvider.resolveFileURL(forPath: urlString) {
            if let onOpenImageFile {
                onOpenImageFile(file)
            } else {
                NSWorkspace.shared.open(file)
            }
            return true
        }
        return false
    }

    /// Double-clicking a rendered image (or its source line) opens the file.
    func openImageIfPresent(onLineAt charIndex: Int) -> Bool {
        let ns = textView.string as NSString
        guard ns.length > 0 else { return false }
        let line = ns.lineRange(for: NSRange(location: min(charIndex, ns.length - 1), length: 0))
        let content = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)

        var path: String?
        if content.hasPrefix("![["), content.hasSuffix("]]") {
            path = String(content.dropFirst(3).dropLast(2))
        } else if content.hasPrefix("!["),
                  let open = content.range(of: "]("), content.hasSuffix(")") {
            path = String(content[open.upperBound..<content.index(before: content.endIndex)])
        }
        guard let path else { return false }
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        if trimmedPath.hasPrefix("http://") || trimmedPath.hasPrefix("https://") {
            if let url = URL(string: trimmedPath) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }
        if let file = layoutController?.imageProvider.resolveFileURL(forPath: trimmedPath) {
            if let onOpenImageFile {
                onOpenImageFile(file)
            } else {
                NSWorkspace.shared.open(file)
            }
            return true
        }
        return false
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

    private func refreshAutocomplete() {
        guard let window = textView.window else {
            autocomplete.hide()
            return
        }
        if let provider = wikiCompletionProvider, let context = wikiQueryContext() {
            show(suggestions: provider(context.query), in: window) { [weak self] picked in
                self?.insertWikiCompletion(picked)
            }
            return
        }
        if let provider = tagCompletionProvider, let context = tagQueryContext() {
            // Rendered with their # so the popup reads as tags, stripped on pick.
            show(suggestions: provider(context.query).map { "#" + $0 }, in: window) { [weak self] picked in
                self?.insertTagCompletion(String(picked.dropFirst()))
            }
            return
        }
        autocomplete.hide()
    }

    private func show(suggestions: [String], in window: NSWindow, onPick: @escaping (String) -> Void) {
        guard !suggestions.isEmpty else {
            autocomplete.hide()
            return
        }
        let caretRect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        autocomplete.show(suggestions: suggestions, at: caretRect, parent: window, onPick: onPick)
    }

    private func insertWikiCompletion(_ target: String) {
        guard let context = wikiQueryContext() else { return }
        let text = textView.string as NSString
        // Replace the partial query (and consume an existing "]]" right after
        // the caret if the tokenizer auto-close ever adds one).
        let replaceRange = context.queryRange
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

    // MARK: # tag autocompletion

    /// Detects "#partial" (possibly a bare "#") immediately before the caret,
    /// mirroring the tokenizer's tag shape: `#` at line start or after
    /// whitespace, followed only by tag characters.
    private func tagQueryContext() -> (query: String, queryRange: NSRange)? {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let caret = selection.location
        guard selection.length == 0, caret > 0, caret <= text.length else { return nil }

        func isTagChar(_ c: unichar) -> Bool {
            (c >= unichar(UInt8(ascii: "0")) && c <= unichar(UInt8(ascii: "9")))
                || (c >= unichar(UInt8(ascii: "a")) && c <= unichar(UInt8(ascii: "z")))
                || (c >= unichar(UInt8(ascii: "A")) && c <= unichar(UInt8(ascii: "Z")))
                || c > 0x7F
                || c == unichar(UInt8(ascii: "_"))
                || c == unichar(UInt8(ascii: "-"))
                || c == unichar(UInt8(ascii: "/"))
        }
        var i = caret - 1
        while i >= 0, isTagChar(text.character(at: i)) { i -= 1 }
        guard i >= 0, text.character(at: i) == unichar(UInt8(ascii: "#")) else { return nil }
        if i > 0 {
            let prev = text.character(at: i - 1)
            let precededBySpace = prev == unichar(UInt8(ascii: " ")) || prev == 0x09
                || prev == 0x0A || prev == 0x0D
            guard precededBySpace else { return nil }
        }
        let queryStart = i + 1
        let queryRange = NSRange(location: queryStart, length: caret - queryStart)
        return (text.substring(with: queryRange), queryRange)
    }

    private func insertTagCompletion(_ name: String) {
        guard let context = tagQueryContext() else { return }
        // Trailing space closes the tag — otherwise the caret would still sit
        // in a tag context and the popup would immediately reopen.
        let insert = name + " "
        if textView.shouldChangeText(in: context.queryRange, replacementString: insert) {
            textView.textStorage?.replaceCharacters(in: context.queryRange, with: insert)
            textView.didChangeText()
            let newCaret = context.queryRange.location + (insert as NSString).length
            textView.setSelectedRange(NSRange(location: newCaret, length: 0))
        }
        autocomplete.hide()
    }

    // MARK: Live Preview — active paragraph tracking

    public func textViewDidChangeSelection(_ notification: Notification) {
        if autocomplete.isActive, wikiQueryContext() == nil, tagQueryContext() == nil {
            autocomplete.hide()
        }
        guard let storage = textView.textStorage else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound else { return }
        // Any natively made selection (mouse drag, shift-arrows) enters
        // visual mode; collapsing it by click leaves visual.
        vim.syncNativeSelection(selection)
        let paragraph = text.length == 0
            ? NSRange(location: 0, length: 0)
            : text.paragraphRange(for: NSRange(
                location: min(selection.location, text.length),
                length: min(selection.length, max(0, text.length - selection.location))
              ))
        highlighter.updateActiveParagraph(storage, to: paragraph)
        refreshCaretShape()
        // Entering/leaving a mermaid block flips it between canvas and source.
        refreshMermaidOverlays()
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
