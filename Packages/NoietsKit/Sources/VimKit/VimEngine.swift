import Foundation

/// The vim modal engine: Normal/Insert/Visual modes, `[count] operator
/// [count] motion|textobject` grammar, one undo group per command, dot-repeat
/// via key replay, and `/` search. Pure Foundation — drives any VimTextTarget.
@MainActor
public final class VimEngine {
    public enum Operator: Equatable {
        case delete, change, yank
    }

    public private(set) var mode: VimMode = .normal {
        didSet { if oldValue != mode { onModeChange?(mode) } }
    }

    public weak var target: VimTextTarget?
    public var onModeChange: ((VimMode) -> Void)?
    /// Status line text (search buffer, pending keys). Empty = clear.
    public var onStatus: ((String) -> Void)?
    /// Fired when the : command line opens/closes (editor shows line numbers).
    public var onCommandMode: ((Bool) -> Void)?

    // Pending command state
    private var count = 0
    private var operatorCount = 0
    private var pendingOperator: Operator?
    private var pendingG = false
    private enum CharWait {
        case find(forward: Bool, till: Bool)
        case replace
        case textObject(around: Bool)
    }
    private var charWait: CharWait?
    private var goalColumn: Int?

    // Visual
    private var visualAnchor = 0

    // Yank register (single, registerless per spec)
    private var yankText = ""
    private var yankLinewise = false

    // Find repeat (; ,)
    private var lastFind: (char: Character, forward: Bool, till: Bool)?

    // : command line (go-to-line)
    private var commandActive = false
    private var commandBuffer = ""

    // Search
    private var searchActive = false
    private var searchBuffer = ""
    private var lastSearch: String?
    private var lastSearchWordBounded = false // set by * and # (\b…\b matching)
    private var searchDirectionForward = true // n repeats in this direction

    // Dot repeat: replay the keys of the last change; insert content is
    // captured text, not keys.
    private var sequence: [VimKey] = []
    private var lastChangeKeys: [VimKey]?
    private var lastInsertText = ""
    private var insertCapture = ""
    private var isReplaying = false
    private var didMutate = false
    private var undoGroupOpen = false

    public init() {}

    /// Hard reset (e.g. when the editor switches to another note).
    public func reset() {
        resetPending()
        closeUndoGroupIfNeeded()
        if commandActive {
            commandActive = false
            commandBuffer = ""
            onCommandMode?(false)
        }
        searchActive = false
        searchBuffer = ""
        insertCapture = ""
        mode = .normal
        statusUpdate()
    }

    // MARK: - Entry

    /// Returns true if the key was consumed (the editor must not process it).
    @discardableResult
    public func handleKey(_ key: VimKey) -> Bool {
        guard target != nil else { return false }
        if key.hasCommand { return false } // never eat menu shortcuts

        if searchActive { return handleSearchKey(key) }
        if commandActive { return handleCommandKey(key) }

        switch mode {
        case .insert:
            return handleInsertKey(key)
        case .normal, .visual, .operatorPending:
            return handleNormalKey(key)
        }
    }

    /// The editor calls this from insertText during insert mode (dot-repeat capture).
    public func recordInsertedText(_ s: String) {
        if mode == .insert, !isReplaying {
            insertCapture += s
        }
    }

    /// The editor calls this when deleteBackward fires in insert mode.
    public func recordBackspace() {
        if mode == .insert, !isReplaying, !insertCapture.isEmpty {
            insertCapture.removeLast()
        }
    }

    // MARK: - Insert mode

    private func handleInsertKey(_ key: VimKey) -> Bool {
        let ctrlBracket = key.hasControl && key.characters == "["
        if key.isEscape || ctrlBracket {
            exitInsert()
            return true
        }
        return false // let the editor (and IME) handle everything else
    }

    private func exitInsert() {
        guard let target else { return }
        lastInsertText = insertCapture
        insertCapture = ""
        // Vim leaves the caret one left of where typing ended.
        let caret = target.selection.location
        let lineStart = Motions.lineStart(target.text, at: min(caret, max(0, target.text.length - 1)))
        if caret > lineStart {
            target.selection = NSRange(location: caret - 1, length: 0)
        }
        closeUndoGroupIfNeeded()
        target.breakUndoCoalescing()
        commitChangeRecordingAfterInsert()
        mode = .normal
        clampCaret()
    }

    // MARK: - Normal / visual mode

    private func handleNormalKey(_ key: VimKey) -> Bool {
        guard let target else { return false }

        if key.isEscape || (key.hasControl && key.characters == "[") {
            resetPending()
            closeUndoGroupIfNeeded() // escape is a hard stop
            if case .visual = mode {
                target.selection = NSRange(location: caretForVisualExit(), length: 0)
                mode = .normal
            }
            statusUpdate()
            return true
        }

        // Start a fresh recording sequence at an idle boundary.
        if !isReplaying, mode == .normal, pendingOperator == nil, charWait == nil,
           !pendingG, count == 0, operatorCount == 0 {
            sequence = []
        }
        if !isReplaying { sequence.append(key) }

        if key.hasControl {
            switch key.characters {
            case "r":
                target.performRedo()
                clampCaret()
            case "d", "u":
                // Half-page scroll, vim-style: caret moves with the view.
                let half = max(1, target.visibleLineCount() / 2)
                moveVertically(lines: key.characters == "d" ? half : -half)
            default:
                break
            }
            return true // consume all control chords in normal mode
        }

        if key.isReturn {
            let t = target.text
            let next = Motions.vertical(t, from: caret, lines: 1, goalColumn: 0)
            moveCaret(to: Motions.firstNonBlank(t, at: next))
            return true
        }

        guard let ch = key.char else { return true }

        // A pending one-char argument (f/t/r or text object selector)?
        if let wait = charWait {
            charWait = nil
            handleCharArgument(wait, char: ch)
            statusUpdate()
            return true
        }

        // g-prefix
        if pendingG {
            pendingG = false
            if ch == "g" {
                applyMotion(.gotoLine(nil, first: true), linewiseForOperator: true)
            }
            statusUpdate()
            return true
        }

        // Counts
        if let digit = ch.wholeNumberValue, ch.isNumber {
            if ch == "0", count == 0 {
                applyMotion(.lineStart, linewiseForOperator: false)
                return true
            }
            count = count * 10 + digit
            statusUpdate()
            return true
        }

        dispatchCommand(ch)
        statusUpdate()
        return true
    }

    private func dispatchCommand(_ ch: Character) {
        guard let target else { return }
        let t = target.text

        switch ch {
        // MARK: Operators
        case "d", "c", "y":
            let op: Operator = ch == "d" ? .delete : (ch == "c" ? .change : .yank)
            if case .visual = mode {
                operateOnVisual(op)
            } else if pendingOperator == op {
                operateOnLines(op) // dd cc yy
            } else if pendingOperator != nil {
                resetPending()
            } else {
                pendingOperator = op
                operatorCount = count
                count = 0
                mode = .operatorPending
            }

        // MARK: Motions
        case "h": applyMotion(.left, linewiseForOperator: false)
        case "l": applyMotion(.right, linewiseForOperator: false)
        case "j": applyMotion(.down, linewiseForOperator: true)
        case "k": applyMotion(.up, linewiseForOperator: true)
        case "w": applyMotion(.wordForward(big: false), linewiseForOperator: false)
        case "W": applyMotion(.wordForward(big: true), linewiseForOperator: false)
        case "b": applyMotion(.wordBackward(big: false), linewiseForOperator: false)
        case "B": applyMotion(.wordBackward(big: true), linewiseForOperator: false)
        case "e": applyMotion(.wordEnd(big: false), linewiseForOperator: false)
        case "E": applyMotion(.wordEnd(big: true), linewiseForOperator: false)
        case "$": applyMotion(.lineEnd, linewiseForOperator: false)
        case "^": applyMotion(.firstNonBlank, linewiseForOperator: false)
        case "{": applyMotion(.paragraphBack, linewiseForOperator: false)
        case "}": applyMotion(.paragraphForward, linewiseForOperator: false)
        case "%": applyMotion(.matchBracket, linewiseForOperator: false)
        case "G":
            applyMotion(.gotoLine(count == 0 ? nil : count, first: false), linewiseForOperator: true)
        case "g":
            pendingG = true

        case "f": charWait = .find(forward: true, till: false)
        case "F": charWait = .find(forward: false, till: false)
        case "t": charWait = .find(forward: true, till: true)
        case "T": charWait = .find(forward: false, till: true)
        case ";", ",":
            if let f = lastFind {
                let forward = ch == ";" ? f.forward : !f.forward
                applyMotion(.findChar(f.char, forward: forward, till: f.till), linewiseForOperator: false)
            }

        // MARK: Insert-entering / text-object prefixes
        case "i":
            if pendingOperator != nil || isVisual {
                charWait = .textObject(around: false) // diw, vi(
            } else {
                enterInsert(.atCaret)
            }
        case "a":
            if pendingOperator != nil || isVisual {
                charWait = .textObject(around: true) // daw, va"
            } else {
                enterInsert(.after)
            }
        case "I": enterInsert(.firstNonBlank)
        case "A": enterInsert(.lineEnd)
        case "o": enterInsert(.openBelow)
        case "O": enterInsert(.openAbove)
        case "s": // substitute char = c + right
            beginChange()
            let end = Motions.right(t, from: caret, count: max(count, 1), allowEnd: true)
            replaceForOperator(NSRange(location: caret, length: max(0, end - caret)), linewise: false)
            enterInsert(.atCaret, alreadyMutating: true)

        // MARK: Immediate edits
        case "x":
            beginChange()
            let end = Motions.right(t, from: caret, count: max(count, 1), allowEnd: true)
            let range = NSRange(location: caret, length: max(0, end - caret))
            yank(range, linewise: false)
            mutate(range, with: "")
            finishChange()
        case "X":
            beginChange()
            let start = Motions.left(t, from: caret, count: max(count, 1))
            let range = NSRange(location: start, length: caret - start)
            if range.length > 0 {
                yank(range, linewise: false)
                mutate(range, with: "")
            }
            finishChange()
        case "r":
            charWait = .replace
        case "~":
            beginChange()
            let end = Motions.right(t, from: caret, count: max(count, 1), allowEnd: true)
            let range = NSRange(location: caret, length: max(0, end - caret))
            if range.length > 0 {
                let flipped = String(t.substring(with: range).map { c in
                    c.isUppercase ? Character(c.lowercased()) : Character(c.uppercased())
                })
                mutate(range, with: flipped)
                moveCaret(to: min(range.location + range.length, maxCaret))
            }
            finishChange()
        case "J":
            joinLines()
        case "p":
            paste(after: true)
        case "P":
            paste(after: false)

        case "D":
            operateToLineEnd(.delete)
        case "C":
            operateToLineEnd(.change)
        case "Y":
            operateOnLines(.yank)
        case "S":
            operateOnLines(.change)

        // MARK: Visual
        case "v":
            if case .visual(false) = modeVisual() {
                exitVisual()
            } else {
                enterVisual(line: false)
            }
        case "V":
            if case .visual(true) = modeVisual() {
                exitVisual()
            } else {
                enterVisual(line: true)
            }

        // MARK: Undo / search
        case "u":
            target.performUndo()
            clampCaret()
        case "/":
            searchActive = true
            searchBuffer = ""
            statusUpdate()
        case ":":
            commandActive = true
            commandBuffer = ""
            onCommandMode?(true)
            statusUpdate()
        case "*":
            searchWordUnderCaret(forward: true)
        case "#":
            searchWordUnderCaret(forward: false)
        case "n":
            searchNext(forward: searchDirectionForward)
        case "N":
            searchNext(forward: !searchDirectionForward)
        case ".":
            repeatLastChange()

        default:
            resetPending()
        }
    }

    // MARK: - Motions plumbing

    private enum Motion {
        case left, right, down, up
        case wordForward(big: Bool), wordBackward(big: Bool), wordEnd(big: Bool)
        case lineStart, lineEnd, firstNonBlank
        case paragraphForward, paragraphBack
        case matchBracket
        case gotoLine(Int?, first: Bool)
        case findChar(Character, forward: Bool, till: Bool)
    }

    private var isVisual: Bool {
        if case .visual = mode { return true }
        return false
    }

    /// Where the editor should draw the block caret: the visual head while
    /// selecting, else the insertion point.
    public var displayCaret: Int {
        if isVisual { return min(visualHead, maxCaret) }
        return caret
    }

    private func modeVisual() -> VimMode { mode }

    private var caret: Int {
        get { target?.selection.location ?? 0 }
    }

    private var maxCaret: Int {
        max(0, (target?.text.length ?? 1) - 1)
    }

    private func effectiveCount() -> Int {
        max(count, 1) * max(operatorCount, 1)
    }

    private func motionTarget(_ motion: Motion, from position: Int, forOperator: Bool) -> (target: Int, inclusive: Bool)? {
        guard let target else { return nil }
        let t = target.text
        let n = effectiveCount()
        switch motion {
        case .left:
            return (Motions.left(t, from: position, count: n), false)
        case .right:
            return (Motions.right(t, from: position, count: n, allowEnd: forOperator), false)
        case .down:
            return (Motions.vertical(t, from: position, lines: n, goalColumn: currentGoalColumn()), false)
        case .up:
            return (Motions.vertical(t, from: position, lines: -n, goalColumn: currentGoalColumn()), false)
        case .wordForward(let big):
            if forOperator {
                return (Motions.wordForwardForOperator(t, from: position, count: n, big: big), false)
            }
            return (Motions.wordForward(t, from: position, count: n, big: big), false)
        case .wordBackward(let big):
            return (Motions.wordBackward(t, from: position, count: n, big: big), false)
        case .wordEnd(let big):
            return (Motions.wordEnd(t, from: position, count: n, big: big), true)
        case .lineStart:
            return (Motions.lineStart(t, at: position), false)
        case .lineEnd:
            let end = Motions.lineContentEnd(t, at: position)
            return forOperator ? (end, false) : (max(Motions.lineStart(t, at: position), end - 1), false)
        case .firstNonBlank:
            return (Motions.firstNonBlank(t, at: position), false)
        case .paragraphForward:
            return (Motions.paragraphForward(t, from: position, count: n), false)
        case .paragraphBack:
            return (Motions.paragraphBackward(t, from: position, count: n), false)
        case .matchBracket:
            guard let m = Motions.matchBracket(t, from: position) else { return nil }
            return (m, true)
        case .gotoLine(let line, let first):
            return (Motions.gotoLine(t, line: line, last: !first && line == nil), false)
        case .findChar(let c, let forward, let till):
            guard let f = Motions.findOnLine(t, from: position, char: c, forward: forward, till: till, count: n) else {
                return nil
            }
            return (f, true)
        }
    }

    private func isLinewiseMotion(_ motion: Motion) -> Bool {
        switch motion {
        case .down, .up, .gotoLine: return true
        default: return false
        }
    }

    private func currentGoalColumn() -> Int {
        if let goalColumn { return goalColumn }
        guard let target else { return 0 }
        let col = Motions.column(target.text, of: caret)
        goalColumn = col
        return col
    }

    private func applyMotion(_ motion: Motion, linewiseForOperator: Bool) {
        guard let target else { return }
        let t = target.text

        // Track goal column across j/k only.
        switch motion {
        case .down, .up: _ = currentGoalColumn()
        default: goalColumn = nil
        }

        // Caret j/k moves by VISUAL lines (wrapped text navigates every
        // rendered line, with a pixel-stable column). Operators below keep
        // logical-line semantics (dj = two real lines), like vim.
        if pendingOperator == nil {
            switch motion {
            case .down:
                moveVertically(lines: effectiveCount())
                return
            case .up:
                moveVertically(lines: -effectiveCount())
                return
            default:
                break
            }
        }

        if let op = pendingOperator {
            // `cw` behaves like `ce` when the caret is on a word char.
            var effectiveMotion = motion
            if op == .change, case .wordForward(let big) = motion,
               caret < t.length,
               Motions.charClass(t.character(at: caret), big: big) != .blank {
                effectiveMotion = .wordEnd(big: big)
            }
            guard let (targetPos, inclusive) = motionTarget(effectiveMotion, from: caret, forOperator: true) else {
                resetPending()
                return
            }
            beginChange()
            if isLinewiseMotion(motion) {
                let startLine = Motions.lineRange(t, at: min(caret, targetPos))
                let endLine = Motions.lineRange(t, at: max(caret, targetPos))
                let range = NSRange(location: startLine.location,
                                    length: endLine.location + endLine.length - startLine.location)
                performOperator(op, on: range, linewise: true)
            } else {
                let lo = min(caret, targetPos)
                var hi = max(caret, targetPos)
                if inclusive { hi = min(hi + 1, t.length) }
                performOperator(op, on: NSRange(location: lo, length: hi - lo), linewise: false)
            }
            return
        }

        // Visual-mode motions move the head, not the selection start.
        let origin = isVisual ? visualHead : caret
        guard let (targetPos, _) = motionTarget(motion, from: origin, forOperator: false) else {
            count = 0
            return
        }
        if isVisual {
            updateVisualSelection(head: targetPos)
        } else {
            moveCaret(to: targetPos)
        }
        count = 0
    }

    /// Visual-line vertical movement for the caret (and the visual-mode head).
    private func moveVertically(lines: Int) {
        guard let target else { return }
        if isVisual {
            // Park the caret at the head, let the editor do the visual move,
            // then rebuild the vim selection around the new head.
            target.selection = NSRange(location: min(visualHead, maxCaret), length: 0)
            target.moveCaretVisually(lines: lines)
            updateVisualSelection(head: target.selection.location)
        } else {
            target.moveCaretVisually(lines: lines)
            target.scrollCaretToVisible()
        }
        count = 0
    }

    private func moveCaret(to position: Int) {
        guard let target else { return }
        let clamped = min(max(position, 0), max(0, target.text.length))
        target.selection = NSRange(location: clamped, length: 0)
        target.scrollCaretToVisible()
        count = 0
    }

    private func clampCaret() {
        guard let target, target.text.length > 0 else { return }
        let clamped = Motions.clampToLine(target.text, min(caret, target.text.length - 1))
        if clamped != caret {
            target.selection = NSRange(location: clamped, length: 0)
        }
    }

    // MARK: - Operators

    private func performOperator(_ op: Operator, on range: NSRange, linewise: Bool) {
        guard range.length > 0 || op == .change else {
            resetPending()
            finishChange()
            return
        }
        yank(range, linewise: linewise)
        switch op {
        case .yank:
            moveCaret(to: range.location)
            resetPending()
            finishChange()
            mode = .normal
        case .delete:
            mutate(range, with: "")
            moveCaret(to: min(range.location, maxCaret))
            clampCaret()
            resetPending()
            finishChange()
            mode = .normal
        case .change:
            if linewise {
                // cc: keep the line, clear its content.
                let content = contentRangeOfLines(range)
                mutate(content, with: "")
                target?.selection = NSRange(location: content.location, length: 0)
            } else {
                mutate(range, with: "")
                target?.selection = NSRange(location: range.location, length: 0)
            }
            resetPending()
            enterInsert(.atCaret, alreadyMutating: true)
        }
    }

    private func replaceForOperator(_ range: NSRange, linewise: Bool) {
        yank(range, linewise: linewise)
        mutate(range, with: "")
        target?.selection = NSRange(location: range.location, length: 0)
    }

    /// dd/yy/cc with counts.
    private func operateOnLines(_ op: Operator) {
        guard let target else { return }
        let t = target.text
        let n = effectiveCount()
        let start = Motions.lineRange(t, at: caret)
        var end = start
        for _ in 1..<n {
            let next = end.location + end.length
            if next >= t.length { break }
            end = Motions.lineRange(t, at: next)
        }
        let range = NSRange(location: start.location, length: end.location + end.length - start.location)
        beginChange()
        performOperator(op, on: range, linewise: true)
    }

    private func operateToLineEnd(_ op: Operator) {
        guard let target else { return }
        let end = Motions.lineContentEnd(target.text, at: caret)
        beginChange()
        performOperator(op, on: NSRange(location: caret, length: max(0, end - caret)), linewise: false)
    }

    private func operateOnVisual(_ op: Operator) {
        guard let target else { return }
        let selection = target.selection
        let linewise: Bool
        if case .visual(true) = mode { linewise = true } else { linewise = false }
        beginChange()
        mode = .normal
        performOperator(op, on: selection, linewise: linewise)
    }

    private func contentRangeOfLines(_ lineRange: NSRange) -> NSRange {
        guard let target else { return lineRange }
        let t = target.text
        var end = lineRange.location + lineRange.length
        if end > lineRange.location, Motions.isNewline(t.character(at: end - 1)) { end -= 1 }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    // MARK: - Yank / paste

    private func yank(_ range: NSRange, linewise: Bool) {
        guard let target, range.length > 0, range.location + range.length <= target.text.length else {
            if range.length == 0 { yankText = ""; yankLinewise = linewise }
            return
        }
        yankText = target.text.substring(with: range)
        yankLinewise = linewise
    }

    private func paste(after: Bool) {
        guard let target, !yankText.isEmpty else { count = 0; return }
        let t = target.text
        beginChange()
        let times = max(count, 1)
        var payload = String(repeating: yankText, count: times)
        if yankLinewise {
            if !payload.hasSuffix("\n") { payload += "\n" }
            let line = Motions.lineRange(t, at: caret)
            var insertAt: Int
            if after {
                insertAt = line.location + line.length
                // Last line without trailing newline: prepend one.
                if insertAt == t.length, insertAt > 0, !Motions.isNewline(t.character(at: insertAt - 1)) {
                    payload = "\n" + payload
                    if payload.hasSuffix("\n") { payload.removeLast() }
                }
            } else {
                insertAt = line.location
            }
            mutate(NSRange(location: insertAt, length: 0), with: payload)
            moveCaret(to: Motions.firstNonBlank(target.text, at: min(insertAt + (payload.hasPrefix("\n") ? 1 : 0), max(0, target.text.length - 1))))
        } else {
            let insertAt = after ? min(caret + (t.length > 0 ? 1 : 0), t.length) : caret
            mutate(NSRange(location: insertAt, length: 0), with: payload)
            moveCaret(to: max(insertAt, min(insertAt + (payload as NSString).length - 1, maxCaret)))
        }
        finishChange()
        count = 0
    }

    // MARK: - Line ops

    private func joinLines() {
        guard target != nil else { return }
        beginChange()
        let joins = max(max(count, 1), 2) - 1
        var position = caret
        for _ in 0..<joins {
            guard let text = target?.text else { break }
            let end = Motions.lineContentEnd(text, at: position)
            guard end < text.length else { break }
            // Replace newline + following indent with a single space.
            var next = end + 1
            while next < text.length, Motions.isBlank(text.character(at: next)) { next += 1 }
            mutate(NSRange(location: end, length: next - end), with: " ")
            position = end
        }
        moveCaret(to: position)
        finishChange()
    }

    // MARK: - Insert entry

    private enum InsertEntry {
        case atCaret, after, firstNonBlank, lineEnd, openBelow, openAbove
    }

    private func enterInsert(_ entry: InsertEntry, alreadyMutating: Bool = false) {
        guard let target else { return }
        let t = target.text

        if !alreadyMutating {
            beginChange()
        }

        var insertPos = caret
        switch entry {
        case .atCaret:
            break
        case .after:
            insertPos = t.length == 0 ? 0 : min(caret + 1, Motions.lineContentEnd(t, at: caret))
        case .firstNonBlank:
            insertPos = Motions.firstNonBlank(t, at: caret)
        case .lineEnd:
            insertPos = Motions.lineContentEnd(t, at: caret)
        case .openBelow:
            let end = Motions.lineContentEnd(t, at: caret)
            mutate(NSRange(location: end, length: 0), with: "\n")
            insertPos = end + 1
        case .openAbove:
            let start = Motions.lineStart(t, at: caret)
            mutate(NSRange(location: start, length: 0), with: "\n")
            insertPos = start
        }

        if isReplaying {
            // Dot-repeat: splice the captured text directly instead of entering
            // insert mode.
            mutate(NSRange(location: insertPos, length: 0), with: lastInsertText)
            let after = insertPos + (lastInsertText as NSString).length
            target.selection = NSRange(location: max(insertPos, after - 1), length: 0)
            closeUndoGroupIfNeeded()
            mode = .normal
            clampCaret()
            resetPending()
            return
        }

        target.selection = NSRange(location: insertPos, length: 0)
        target.breakUndoCoalescing()
        insertCapture = ""
        mode = .insert
        count = 0
        operatorCount = 0
    }

    // MARK: - Char arguments (f/t/r/text objects)

    private func handleCharArgument(_ wait: CharWait, char: Character) {
        guard let target else { return }
        switch wait {
        case .find(let forward, let till):
            lastFind = (char, forward, till)
            applyMotion(.findChar(char, forward: forward, till: till), linewiseForOperator: false)
        case .replace:
            let t = target.text
            let n = max(count, 1)
            guard caret + n <= Motions.lineContentEnd(t, at: caret) else {
                count = 0
                return
            }
            beginChange()
            let range = NSRange(location: caret, length: n)
            mutate(range, with: String(repeating: String(char), count: n))
            moveCaret(to: range.location + range.length - 1)
            finishChange()
        case .textObject(let around):
            guard let kind = TextObjects.kind(for: char),
                  let result = TextObjects.range(target.text, at: caret, kind: kind, around: around) else {
                resetPending()
                return
            }
            if isVisual {
                target.selection = result.range
                visualAnchor = result.range.location
                visualHead = max(result.range.location,
                                 result.range.location + result.range.length - 1)
                return
            }
            guard let op = pendingOperator else {
                resetPending()
                return
            }
            beginChange()
            performOperator(op, on: result.range, linewise: result.linewise)
        }
    }

    // MARK: - Visual selection

    private func updateVisualSelection(head: Int) {
        guard let target else { return }
        let t = target.text
        // Update the head BEFORE touching the selection: assigning it fires
        // the editor's selection-change hook synchronously, and the caret
        // renderer reads displayCaret (= visualHead) right then. The old
        // order left the block caret painted at the previous session's head.
        visualHead = head
        if case .visual(true) = mode {
            let a = Motions.lineRange(t, at: min(visualAnchor, head))
            let b = Motions.lineRange(t, at: max(visualAnchor, head))
            target.selection = NSRange(location: a.location, length: b.location + b.length - a.location)
        } else {
            let lo = min(visualAnchor, head)
            let hi = max(visualAnchor, head)
            // Vim selections are inclusive of the char under the head.
            target.selection = NSRange(location: lo, length: min(hi + 1, t.length) - lo)
        }
        target.scrollCaretToVisible()
        count = 0
    }

    private var visualHead = 0

    private func enterVisual(line: Bool) {
        // Seed anchor + head before the mode change so the caret renderer
        // (fired by onModeChange) never sees a stale head.
        visualAnchor = caret
        visualHead = caret
        mode = .visual(line: line)
        updateVisualSelection(head: caret)
    }

    /// Leaving visual collapses the selection to the head (vim behavior) —
    /// otherwise the 1-char native highlight lingers.
    private func exitVisual() {
        let resting = caretForVisualExit()
        mode = .normal
        target?.selection = NSRange(location: resting, length: 0)
        clampCaret()
    }

    private func caretForVisualExit() -> Int {
        min(visualHead, maxCaret)
    }

    // MARK: - Search

    // MARK: - : command line

    private func handleCommandKey(_ key: VimKey) -> Bool {
        func close() {
            commandActive = false
            commandBuffer = ""
            onCommandMode?(false)
            statusUpdate()
        }
        if key.isEscape || (key.hasControl && key.characters == "[") {
            close()
            return true
        }
        if key.isReturn {
            if let target, let line = Int(commandBuffer), line > 0,
               let location = target.characterLocation(ofVisualRow: line) {
                moveCaret(to: location)
            }
            close()
            return true
        }
        if key.isBackspace {
            if commandBuffer.isEmpty {
                close()
            } else {
                commandBuffer.removeLast()
                statusUpdate()
            }
            return true
        }
        // Go-to-line only: digits build the target.
        if let ch = key.char, ch.isNumber {
            commandBuffer.append(ch)
            statusUpdate()
        }
        return true
    }

    private func handleSearchKey(_ key: VimKey) -> Bool {
        if key.isEscape {
            searchActive = false
            searchBuffer = ""
            statusUpdate()
            return true
        }
        if key.isReturn {
            searchActive = false
            if !searchBuffer.isEmpty {
                lastSearch = searchBuffer
                lastSearchWordBounded = false
                searchDirectionForward = true
                searchNext(forward: true, includeCurrent: false)
            }
            searchBuffer = ""
            statusUpdate()
            return true
        }
        if key.isBackspace {
            if searchBuffer.isEmpty {
                searchActive = false
            } else {
                searchBuffer.removeLast()
            }
            statusUpdate()
            return true
        }
        if !key.characters.isEmpty, !key.hasControl {
            searchBuffer += key.characters
            statusUpdate()
            return true
        }
        return true
    }

    /// Vim's * / #: search for the word under (or after) the caret, forward
    /// or backward, whole-word matched. n/N continue in the same direction.
    private func searchWordUnderCaret(forward: Bool) {
        guard let target else { return }
        let t = target.text
        guard t.length > 0 else { return }

        // Word under the caret, or the next word on the line (vim behavior).
        var i = min(caret, t.length - 1)
        let lineEnd = Motions.lineContentEnd(t, at: i)
        while i < lineEnd, !Motions.isWordChar(t.character(at: i)) { i += 1 }
        guard i < t.length, Motions.isWordChar(t.character(at: i)) else { return }
        var start = i
        var end = i
        while start > 0, Motions.isWordChar(t.character(at: start - 1)) { start -= 1 }
        while end < t.length - 1, Motions.isWordChar(t.character(at: end + 1)) { end += 1 }

        lastSearch = t.substring(with: NSRange(location: start, length: end - start + 1))
        lastSearchWordBounded = true
        searchDirectionForward = forward
        // Anchor at the word start so "previous" means an earlier occurrence.
        if caret != start {
            target.selection = NSRange(location: start, length: 0)
        }
        searchNext(forward: forward)
    }

    private func searchNext(forward: Bool, includeCurrent: Bool = false) {
        guard let target, let query = lastSearch, !query.isEmpty else { return }
        let t = target.text
        guard t.length > 0 else { return }

        // Smartcase: all-lowercase query searches case-insensitively.
        var options: NSRegularExpression.Options = []
        if query == query.lowercased() { options.insert(.caseInsensitive) }
        var pattern = NSRegularExpression.escapedPattern(for: query)
        if lastSearchWordBounded { pattern = "\\b\(pattern)\\b" }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }

        let matches = regex.matches(in: t as String, range: NSRange(location: 0, length: t.length))
            .map(\.range)
        guard !matches.isEmpty else { return }

        let selection = target.selection
        let found: NSRange
        if forward {
            let from: Int
            if includeCurrent {
                from = selection.location
            } else if selection.length > 0 {
                from = selection.location + selection.length
            } else {
                from = selection.location + 1
            }
            found = matches.first { $0.location >= from } ?? matches[0] // wrap
        } else {
            found = matches.last { $0.location < selection.location }
                ?? matches[matches.count - 1] // wrap
        }
        target.selection = found
        target.scrollCaretToVisible()
        count = 0
    }

    // MARK: - Dot repeat

    private func beginChange() {
        didMutate = false
        if !undoGroupOpen {
            target?.beginUndoGroup()
            undoGroupOpen = true
        }
    }

    private func finishChange() {
        closeUndoGroupIfNeeded()
        if didMutate, !isReplaying {
            lastChangeKeys = sequence
        }
        didMutate = false
    }

    private func commitChangeRecordingAfterInsert() {
        if !isReplaying {
            lastChangeKeys = sequence
        }
    }

    private func closeUndoGroupIfNeeded() {
        if undoGroupOpen {
            target?.endUndoGroup()
            undoGroupOpen = false
        }
    }

    private func mutate(_ range: NSRange, with string: String) {
        target?.replace(range, with: string)
        didMutate = true
    }

    private func repeatLastChange() {
        guard let keys = lastChangeKeys, !keys.isEmpty else { return }
        isReplaying = true
        resetPending()
        for key in keys {
            _ = handleKey(key)
        }
        // Safety: replay must never strand us in insert mode.
        if mode == .insert {
            closeUndoGroupIfNeeded()
            mode = .normal
        }
        isReplaying = false
    }

    // MARK: - Misc

    private func resetPending() {
        count = 0
        operatorCount = 0
        pendingOperator = nil
        pendingG = false
        charWait = nil
        if mode == .operatorPending { mode = .normal }
        // NOTE: does NOT close the undo group — a `c` command resets pending
        // state while its group must stay open through the insert session.
    }

    private func statusUpdate() {
        if searchActive {
            onStatus?("/" + searchBuffer)
        } else if commandActive {
            onStatus?(":" + commandBuffer)
        } else if pendingOperator != nil || count > 0 {
            var s = ""
            if count > 0 { s += String(count) }
            if let op = pendingOperator {
                s += op == .delete ? "d" : (op == .change ? "c" : "y")
            }
            onStatus?(s)
        } else {
            onStatus?("")
        }
    }
}
