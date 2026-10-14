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
    /// Native j/k movement can make provisional selections before correcting
    /// its sticky column. The cursor trail should use only the final landing.
    var onVisualMoveCompleted: (() -> Void)?

    private struct QuoteLanding {
        let paragraphStart: Int
        let rowIndex: Int
        let rowsFromEnd: Int
    }
    private var quoteLanding: QuoteLanding?
    private var correctingVerticalLanding = false

    private struct SmoothScroll {
        let from: NSPoint
        let to: NSPoint
        let started: CFTimeInterval
    }
    private var smoothScroll: SmoothScroll?
    private var smoothScrollTimer: Timer?
    private var capturingHalfPageScroll = false
    var isSmoothScrolling: Bool { smoothScroll != nil }

    func cancelSmoothScrolling() {
        smoothScrollTimer?.invalidate()
        smoothScrollTimer = nil
        smoothScroll = nil
    }

    /// Animate real clip bounds, so TextKit's viewport and newly exposed rows
    /// stay live throughout the scroll (not a snapshot/layer-only animation).
    func stepSmoothScroll(at time: CFTimeInterval) {
        guard let scroll = smoothScroll, let scrollView = enclosingScrollView else {
            cancelSmoothScrolling()
            return
        }
        let progress = min(max((time - scroll.started) / 0.20, 0), 1)
        let eased = 1 - pow(1 - progress, 3)
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin = NSPoint(x: scroll.from.x + (scroll.to.x - scroll.from.x) * eased,
                                y: scroll.from.y + (scroll.to.y - scroll.from.y) * eased)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
        if progress == 1 { cancelSmoothScrolling() }
    }

    public override func scrollWheel(with event: NSEvent) {
        cancelSmoothScrolling()
        super.scrollWheel(with: event)
    }

    /// Capture the preview row before revealing `>` rewraps the paragraph.
    private func rememberQuoteLanding(at index: Int) {
        guard let row = laidOutRow(at: index), row.fragment is QuoteBarFragment else { return }
        quoteLanding = QuoteLanding(paragraphStart: row.paragraphStart, rowIndex: row.index,
                                    rowsFromEnd: row.fragment.textLineFragments.count - row.index - 1)
    }

    private func reflowedQuoteRow(movingDown: Bool) -> (rect: CGRect, range: NSRange)? {
        guard let landing = quoteLanding, let content = textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: landing.paragraphStart),
              let fragment = textLayoutManager?.textLayoutFragment(for: location),
              !fragment.textLineFragments.isEmpty else { return nil }
        let rows = fragment.textLineFragments
        // Entering from below must still target the last row even if the
        // source version has a different number of wraps than the preview.
        let index = movingDown ? landing.rowIndex : rows.count - landing.rowsFromEnd - 1
        return rowGeometry(in: fragment, at: min(max(index, 0), rows.count - 1),
                           paragraphStart: landing.paragraphStart)
    }

    /// All wrap boundaries come from TextKit 2's shaped line fragments, not
    /// estimated heights, logical paragraphs, or insertion hit-test affinity.
    private func laidOutRow(at position: Int) -> (fragment: NSTextLayoutFragment, index: Int, paragraphStart: Int)? {
        guard text.length > 0 else { return nil }
        let index = min(max(position, 0), text.length - 1)
        ensureLocalLayout(around: index)
        guard let content = textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: index),
              let fragment = textLayoutManager?.textLayoutFragment(for: location) else { return nil }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard let row = fragment.textLineFragments.firstIndex(where: {
            NSLocationInRange(index - start, $0.characterRange)
        }) else { return nil }
        return (fragment, row, start)
    }

    private func rowGeometry(in fragment: NSTextLayoutFragment, at index: Int,
                             paragraphStart: Int) -> (rect: CGRect, range: NSRange) {
        let row = fragment.textLineFragments[index]
        let origin = textContainerOrigin
        return (
            row.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + origin.x,
                                           dy: fragment.layoutFragmentFrame.minY + origin.y),
            NSRange(location: paragraphStart + row.characterRange.location, length: row.characterRange.length)
        )
    }

    /// AppKit exposes a normalized selected range, not which edge the user is
    /// dragging. Keep the insertion-position anchor across native selection
    /// updates so Vim can put its visual head on the correct edge.
    private var nativeSelectionAnchorPosition = 0
    private(set) var vimSelectionEndpoints: (anchor: Int, head: Int)?

    /// Read-only document (the built-in docs): every change is rejected at
    /// the single text-change gate. The view stays `isEditable` so caret
    /// movement keeps normal semantics — a non-editable NSTextView turns
    /// moveDown: into view scrolling and ⌃d/⌃u break.
    public var isReadOnlyDocument = false

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
        // Keep each run's foreground: links are accent-coloured by the
        // highlighter, while clickable tag badges use normal document text.
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        typingAttributes = theme.typingAttributes()
        defaultParagraphStyle = theme.defaultParagraphStyle
        textContainerInset = NSSize(width: 28, height: 28)
    }

    /// Code bands belong below AppKit's selection, not in the fragment's
    /// glyph pass (which otherwise paints opaque code backgrounds over it).
    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let manager = textLayoutManager, let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = textContainerOrigin
        let viewport = manager.textViewportLayoutController.viewportRange
        context.saveGState()
        context.clip(to: rect)
        manager.enumerateTextLayoutFragments(from: viewport?.location ?? manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > rect.maxY { return false }
            if frame.intersects(rect), let code = fragment as? CodeBandFragment {
                code.drawBand(at: frame.origin, in: context)
            }
            return true
        }
        context.restoreGState()
    }

    public override func didChangeText() {
        super.didChangeText()
        // Fence edits can add/remove bands well beyond the edited glyphs.
        needsDisplay = true
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

    /// Returns true when the paste was handled as an image embed.
    public var onPasteImage: (() -> Bool)?

    /// Double-click hook (image lines open externally). Returns true if handled.
    public var onDoubleClick: ((Int) -> Bool)?

    /// Single-click hook for rendered image lines (open/zoom the image).
    /// Returns true if handled — the click then never moves the caret.
    public var onImageLineClick: ((Int) -> Bool)?

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let onDoubleClick {
            let index = characterIndexForInsertion(at: point)
            if index >= 0, onDoubleClick(index) {
                return
            }
        }
        // Single click only counts as an image click when it lands inside a
        // laid-out fragment — clicks in the empty space below the document
        // map to the last line's index and must keep placing the caret.
        if event.clickCount == 1, let onImageLineClick, let layoutManager = textLayoutManager {
            let docPoint = CGPoint(x: point.x - textContainerInset.width,
                                   y: point.y - textContainerInset.height)
            if let fragment = layoutManager.textLayoutFragment(for: docPoint),
               fragment.layoutFragmentFrame.contains(docPoint) {
                let index = characterIndexForInsertion(at: point)
                if index >= 0, onImageLineClick(index) {
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    public override func paste(_ sender: Any?) {
        if let onPasteImage, onPasteImage() {
            return
        }
        super.paste(sender)
    }

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

    public override func shouldChangeText(
        in affectedCharRange: NSRange, replacementString: String?
    ) -> Bool {
        if isReadOnlyDocument { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
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

    // MARK: List continuation

    public override func insertNewline(_ sender: Any?) {
        if continueListItem() { return }
        super.insertNewline(sender)
    }

    /// Return inside a list item continues the list: the new line repeats the
    /// item's indent (tabs preserved) and marker — the next number for ordered
    /// items, an unchecked box for tasks. Return on an empty item clears its
    /// marker instead, ending the list. Uses the block scan, so code-fence
    /// lines that merely start with "- " never trigger it.
    private func continueListItem() -> Bool {
        guard !isReadOnlyDocument else { return false }
        let sel = selectedRange()
        let ns = string as NSString
        guard sel.length == 0, sel.location <= ns.length,
              let scan = (textStorage?.delegate as? IncrementalHighlighter)?.currentScan,
              !scan.lines.isEmpty
        else { return false }
        let line = scan.lines[scan.lineIndex(containing: sel.location)]
        guard case .listItem(let markerRange, let ordered, let task, let contentStart) = line.kind,
              sel.location >= contentStart
        else { return false }

        let lineStart = line.contentRange.location
        let contentEnd = line.contentRange.location + line.contentRange.length

        // Marker with no content: Return ends the list by clearing the marker.
        if contentStart >= contentEnd {
            insertText("", replacementRange:
                NSRange(location: lineStart, length: contentStart - lineStart))
            return true
        }

        // Rebuild the prefix from the scanned ranges: indent … marker …
        // spacing (… task box …) exactly as typed, tabs and all.
        var prefix = ns.substring(with:
            NSRange(location: lineStart, length: markerRange.location - lineStart))
        if ordered {
            let marker = ns.substring(with: markerRange) // e.g. "3." / "3)"
            let digits = marker.prefix { $0.isNumber }
            prefix += "\((Int(digits) ?? 0) + 1)\(marker.dropFirst(digits.count))"
        } else {
            prefix += ns.substring(with: markerRange)
        }
        let markerEnd = markerRange.location + markerRange.length
        if let task {
            prefix += ns.substring(with:
                NSRange(location: markerEnd, length: task.range.location - markerEnd))
            prefix += "[ ]"
            let taskEnd = task.range.location + task.range.length
            prefix += ns.substring(with:
                NSRange(location: taskEnd, length: contentStart - taskEnd))
        } else {
            prefix += ns.substring(with:
                NSRange(location: markerEnd, length: contentStart - markerEnd))
        }
        insertText("\n" + prefix, replacementRange: sel)
        return true
    }

    // MARK: TK2 tripwire

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelSmoothScrolling() }
        if window != nil, textLayoutManager == nil {
            Self.log.fault("TextKit 2 downgrade detected — NoietsTextView fell back to TextKit 1")
            assertionFailure("TextKit 2 downgrade detected")
        }
    }

    // MARK: Centered column

    public override func setFrameSize(_ newSize: NSSize) {
        if abs(newSize.width - frame.width) > 0.5 { cancelSmoothScrolling() }
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
        if !capturingHalfPageScroll { cancelSmoothScrolling() }
        scrollRangeToVisible(selectedRange())
    }

    public func withHalfPageScroll(_ movement: () -> Void) {
        let previousGoal = smoothScroll?.to
        cancelSmoothScrolling()
        guard let scrollView = enclosingScrollView, window != nil else {
            movement()
            return
        }
        let clip = scrollView.contentView
        let from = clip.bounds.origin
        let before = laidOutRow(at: vim?.displayCaret ?? selectedRange().location).map {
            rowGeometry(in: $0.fragment, at: $0.index, paragraphStart: $0.paragraphStart).rect.minY
        }
        capturingHalfPageScroll = true
        defer { capturingHalfPageScroll = false }
        movement()
        let after = laidOutRow(at: vim?.displayCaret ?? selectedRange().location).map {
            rowGeometry(in: $0.fragment, at: $0.index, paragraphStart: $0.paragraphStart).rect.minY
        }
        var destination = clip.bounds
        if let before, let after {
            destination.origin = NSPoint(x: from.x, y: (previousGoal?.y ?? from.y) + after - before)
        }
        let to = clip.constrainBoundsRect(destination).origin
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(to.y - from.y) > 0.5 else {
            clip.scroll(to: to)
            scrollView.reflectScrolledClipView(clip)
            return
        }
        // Native movement may scroll immediately. Restore in the same event
        // turn, then glide from the actual current position; repeated Ctrl+D/U
        // replaces the previous timer without snapping to its unfinished goal.
        clip.scroll(to: from)
        scrollView.reflectScrolledClipView(clip)
        smoothScroll = SmoothScroll(from: from, to: to, started: CACurrentMediaTime())
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            // This timer is registered exclusively on RunLoop.main.
            let alive = MainActor.assumeIsolated {
                guard let self else { return false }
                self.stepSmoothScroll(at: CACurrentMediaTime())
                return true
            }
            if !alive { timer.invalidate() }
        }
        smoothScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func visualLineRange(at position: Int) -> NSRange {
        let ns = text
        if ns.length == 0 { return NSRange(location: 0, length: 0) }
        if position >= ns.length, [0x0A, 0x0D].contains(ns.character(at: ns.length - 1)) {
            return NSRange(location: ns.length, length: 0)
        }
        let range: NSRange
        if let row = laidOutRow(at: position) {
            range = rowGeometry(in: row.fragment, at: row.index, paragraphStart: row.paragraphStart).range
        } else {
            range = Motions.lineRange(ns, at: position)
        }
        var end = min(NSMaxRange(range), ns.length)
        while end > range.location, [0x0A, 0x0D].contains(ns.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: range.location, length: end - range.location)
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
    /// Forces real (non-estimated) layout for the logical line at `location`
    /// plus one line either side — cheap, local, and required before trusting
    /// character rects for caret movement.
    func ensureLocalLayout(around location: Int) {
        guard let layoutManager = textLayoutManager,
              let contentStorage = textContentStorage else { return }
        let ns = string as NSString
        guard ns.length > 0 else { return }
        let line = ns.lineRange(for: NSRange(location: min(location, ns.length - 1), length: 0))
        var start = line.location
        if start > 0 {
            start = ns.lineRange(for: NSRange(location: start - 1, length: 0)).location
        }
        var end = line.location + line.length
        if end < ns.length {
            let next = ns.lineRange(for: NSRange(location: end, length: 0))
            end = next.location + next.length
        }
        let doc = contentStorage.documentRange
        guard let from = contentStorage.location(doc.location, offsetBy: start),
              let to = contentStorage.location(doc.location, offsetBy: end),
              let range = NSTextRange(location: from, end: to) else { return }
        layoutManager.ensureLayout(for: range)
    }

    public func moveCaretVisually(lines: Int) {
        inVerticalMove = true
        defer {
            quoteLanding = nil
            inVerticalMove = false
            onVisualMoveCompleted?()
        }

        // Freshly opened documents may only have ESTIMATED layout around the
        // caret; estimated character rects put every wrapped row at nearly
        // the same y, so the landing hit-test yanks the caret back where it
        // started. Force real layout for the neighborhood first.
        ensureLocalLayout(around: selectedRange().location)

        let goal = verticalGoalX ?? caretViewRect()?.minX
        verticalGoalX = goal

        for _ in 0..<abs(lines) {
            let source = selectedRange().location
            quoteLanding = nil
            if lines > 0 {
                moveDown(nil)
            } else {
                moveUp(nil)
            }
            ensureLocalLayout(around: source)
            ensureLocalLayout(around: selectedRange().location)
            correctVerticalLanding(at: goal, movingDown: lines > 0)
        }
    }

    private func correctVerticalLanding(at goal: CGFloat?, movingDown: Bool) {
        correctingVerticalLanding = true
        defer { correctingVerticalLanding = false }
        // Land on the destination visual line at the remembered x. The result
        // is clamped to the logical line moveDown/moveUp actually reached:
        // on an empty (or short) line a far-out x has no glyphs, and the hit
        // test can otherwise escape to a neighboring line.
        // The row is anchored to the landed CHARACTER's rect — a caret rect
        // at a soft-wrap boundary is affinity-ambiguous and can report the
        // row the move just left, snapping the caret straight back.
        if let goal, let window {
            let ns = string as NSString
            guard ns.length > 0 else { return }
            let landed = min(selectedRange().location, ns.length - 1)
            let landedScreen = firstRect(
                forCharacterRange: NSRange(location: landed, length: 1), actualRange: nil
            )
            guard landedScreen != .zero else { return }
            let mappedRow = reflowedQuoteRow(movingDown: movingDown)
            let lineRect = mappedRow?.rect ?? convert(window.convertFromScreen(landedScreen), from: nil)
            let fallback = mappedRow?.range.location ?? landed
            let lineRange = ns.lineRange(for: NSRange(location: landed, length: 0))
            var contentEnd = lineRange.location + lineRange.length
            if contentEnd > lineRange.location,
               ns.character(at: contentEnd - 1) == 0x0A {
                contentEnd -= 1
            }
            let index = characterIndexForInsertion(at: NSPoint(x: goal, y: lineRect.midY))
            let rowStart = mappedRow?.range.location ?? lineRange.location
            let rowEnd = min(mappedRow.map { NSMaxRange($0.range) } ?? contentEnd, contentEnd)
            var clamped = min(max(index, rowStart), rowEnd)

            // Wrap-boundary guard: a far-x hit on a wrapped row can return the
            // boundary index, whose character belongs to the NEXT visual row.
            // If the char under the caret isn't on the destination row, step
            // back onto it.
            if clamped < ns.length {
                let charScreen = firstRect(
                    forCharacterRange: NSRange(location: clamped, length: 1), actualRange: nil
                )
                if charScreen != .zero {
                    let charRect = convert(window.convertFromScreen(charScreen), from: nil)
                    if abs(charRect.midY - lineRect.midY) > lineRect.height / 2 {
                        clamped = max(rowStart, clamped - 1)
                    }
                }
            }

            // The insertion hit-test can escape the landed row entirely (seen
            // on indented code paragraphs, where it returns the paragraph
            // start and yanks the caret back up). If the adjusted result
            // still isn't on the landed row, trust the native move instead.
            if clamped != landed {
                let adjustedScreen = firstRect(
                    forCharacterRange: NSRange(location: min(clamped, ns.length - 1), length: 1),
                    actualRange: nil
                )
                if adjustedScreen != .zero {
                    let adjustedRect = convert(window.convertFromScreen(adjustedScreen), from: nil)
                    if abs(adjustedRect.midY - lineRect.midY) > lineRect.height / 2 {
                        clamped = fallback
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
            if !capturingHalfPageScroll { cancelSmoothScrolling() }
        }
        if let range = ranges.first?.rangeValue, range.location != NSNotFound {
            let oldRange = selectedRange()
            if inVerticalMove, !correctingVerticalLanding, range.length == 0,
               range.location != oldRange.location {
                rememberQuoteLanding(at: range.location)
            }
            if range.length == 0 {
                nativeSelectionAnchorPosition = range.location
                vimSelectionEndpoints = nil
            } else {
                let upper = NSMaxRange(range)
                if oldRange.length == 0,
                   oldRange.location >= range.location,
                   oldRange.location <= upper {
                    nativeSelectionAnchorPosition = oldRange.location
                } else if nativeSelectionAnchorPosition < range.location
                            || nativeSelectionAnchorPosition > upper {
                    nativeSelectionAnchorPosition = range.location
                }

                if nativeSelectionAnchorPosition >= upper {
                    vimSelectionEndpoints = (anchor: upper - 1, head: range.location)
                } else {
                    vimSelectionEndpoints = (anchor: range.location, head: upper - 1)
                }
            }
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
        // Arrow keys behave as h/j/k/l — same visual-line movement and sticky
        // column in normal/visual mode. (Insert mode never consumes them, so
        // native arrow behavior there is unchanged.)
        let characters: String
        switch event.keyCode {
        case 123: characters = "h"
        case 124: characters = "l"
        case 125: characters = "j"
        case 126: characters = "k"
        default: characters = event.charactersIgnoringModifiers ?? ""
        }
        self.init(
            characters: characters,
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
