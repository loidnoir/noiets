import Foundation
import Testing
@testable import VimKit

/// Snapshot-based mock: one undo entry per top-level group (or ungrouped edit),
/// mirroring how NSUndoManager groups the real editor's changes.
@MainActor
final class MockTarget: VimTextTarget {
    var buffer: NSMutableString
    /// Mirrors the editor: assigning the selection synchronously notifies
    /// observers (the app's caret renderer runs in that moment).
    var selectionObserver: (() -> Void)?
    var selection = NSRange(location: 0, length: 0) {
        didSet {
            if !movingVertically { verticalGoal = nil } // like AppKit's preferred-x
            selectionObserver?()
        }
    }

    private var undoStack: [(String, NSRange)] = []
    private var redoStack: [(String, NSRange)] = []
    private var groupDepth = 0
    private var groupSnapshot: (String, NSRange)?

    init(_ s: String, caret: Int = 0) {
        buffer = NSMutableString(string: s)
        selection = NSRange(location: caret, length: 0)
    }

    var text: NSString { buffer }

    func replace(_ range: NSRange, with string: String) {
        if groupDepth == 0 {
            undoStack.append((buffer as String, selection))
            redoStack = []
        } else if groupSnapshot == nil {
            groupSnapshot = (buffer as String, selection)
        }
        buffer.replaceCharacters(in: range, with: string)
        selection = NSRange(location: range.location + (string as NSString).length, length: 0)
    }

    func beginUndoGroup() { groupDepth += 1 }

    func endUndoGroup() {
        groupDepth = max(0, groupDepth - 1)
        if groupDepth == 0, let snap = groupSnapshot {
            undoStack.append(snap)
            redoStack = []
            groupSnapshot = nil
        }
    }

    func breakUndoCoalescing() {}

    func performUndo() {
        guard let (text, sel) = undoStack.popLast() else { return }
        redoStack.append((buffer as String, selection))
        buffer = NSMutableString(string: text)
        selection = sel
    }

    func performRedo() {
        guard let (text, sel) = redoStack.popLast() else { return }
        undoStack.append((buffer as String, selection))
        buffer = NSMutableString(string: text)
        selection = sel
    }

    func scrollCaretToVisible() {}

    func visibleLineCount() -> Int { 20 }

    func characterLocation(ofVisualRow row: Int) -> Int? {
        Motions.gotoLine(text, line: row, last: false) // logical == visual headless
    }

    /// Headless approximation of AppKit's visual movement: logical lines with
    /// a goal column that persists across consecutive vertical moves (and
    /// resets whenever the selection is set by any other path).
    private var verticalGoal: Int?
    private var movingVertically = false

    func moveCaretVisually(lines: Int) {
        let col = verticalGoal ?? Motions.column(text, of: selection.location)
        verticalGoal = col
        movingVertically = true
        let pos = Motions.vertical(text, from: selection.location, lines: lines, goalColumn: col)
        selection = NSRange(location: pos, length: 0)
        movingVertically = false
    }

    var undoDepth: Int { undoStack.count }
    var s: String { buffer as String }
    var caret: Int { selection.location }
}

@MainActor
private func makeEngine(_ text: String, caret: Int = 0) -> (VimEngine, MockTarget) {
    let target = MockTarget(text, caret: caret)
    let engine = VimEngine()
    engine.target = target
    return (engine, target)
}

@MainActor
private func send(_ engine: VimEngine, _ keys: String) {
    for key in VimKey.sequence(keys) {
        _ = engine.handleKey(key)
    }
}

/// Simulates typing while in insert mode (the editor does the insertion).
@MainActor
private func type(_ engine: VimEngine, _ target: MockTarget, _ text: String) {
    for ch in text {
        target.replace(NSRange(location: target.caret, length: 0), with: String(ch))
        engine.recordInsertedText(String(ch))
    }
}

// MARK: - Motions

@MainActor
@Suite struct MotionTests {
    @Test func basicHJKL() {
        let (e, t) = makeEngine("abc\ndef\nghi", caret: 0)
        send(e, "ll")
        #expect(t.caret == 2)
        send(e, "j")
        #expect(t.caret == 6) // 'f' — goal column 2
        send(e, "h")
        #expect(t.caret == 5)
        send(e, "k")
        #expect(t.caret == 1)
        send(e, "l") // caret can't pass last char in normal mode
        send(e, "l")
        send(e, "l")
        #expect(t.caret == 2)
    }

    @Test func goalColumnPersistsAcrossShortLines() {
        let (e, t) = makeEngine("abcdef\nxy\nabcdef", caret: 4)
        send(e, "j")
        #expect(t.caret == 8) // clamped to 'y'
        send(e, "j")
        #expect(t.caret == 14) // back to column 4
    }

    @Test func wordMotions() {
        let (e, t) = makeEngine("one two, three", caret: 0)
        send(e, "w")
        #expect(t.caret == 4) // two
        send(e, "w")
        #expect(t.caret == 7) // comma (punct run)
        send(e, "w")
        #expect(t.caret == 9) // three
        send(e, "b")
        #expect(t.caret == 7)
        send(e, "e")
        #expect(t.caret == 13) // end of three
        send(e, "bb") // three → comma (a punct run is a word)
        #expect(t.caret == 7)
        send(e, "b")
        #expect(t.caret == 4)
    }

    @Test func lineAnchors() {
        let (e, t) = makeEngine("  hello world", caret: 8)
        send(e, "0")
        #expect(t.caret == 0)
        send(e, "^")
        #expect(t.caret == 2)
        send(e, "$")
        #expect(t.caret == 12) // on 'd'
    }

    @Test func ggAndG() {
        let (e, t) = makeEngine("one\ntwo\nthree\nfour", caret: 5)
        send(e, "G")
        #expect(t.caret == 14) // 'f'
        send(e, "gg")
        #expect(t.caret == 0)
        send(e, "3G")
        #expect(t.caret == 8) // 't' of three
    }

    @Test func findOnLine() {
        let (e, t) = makeEngine("say hello to hexagons", caret: 0)
        send(e, "fh")
        #expect(t.caret == 4)
        send(e, ";")
        #expect(t.caret == 13)
        send(e, ",")
        #expect(t.caret == 4)
        send(e, "tx")
        #expect(t.caret == 14) // till 'x' of hexagons → on 'e'
    }

    @Test func bracketMatch() {
        let (e, t) = makeEngine("foo(bar(baz))", caret: 0)
        send(e, "%") // first bracket on line → its match
        #expect(t.caret == 12)
        send(e, "%")
        #expect(t.caret == 3)
    }

    @Test func paragraphMotions() {
        let (e, t) = makeEngine("one\ntwo\n\nthree\n\nfour", caret: 0)
        send(e, "}")
        #expect(t.caret == 8) // first blank line
        send(e, "}")
        #expect(t.caret == 15)
        send(e, "{")
        #expect(t.caret == 8)
        send(e, "{") // from a blank line, previous boundary is doc start
        #expect(t.caret == 0)
    }
}

// MARK: - Operators

@MainActor
@Suite struct OperatorTests {
    @Test func deleteWord() {
        let (e, t) = makeEngine("one two three", caret: 0)
        send(e, "dw")
        #expect(t.s == "two three")
        #expect(t.caret == 0)
        #expect(t.undoDepth == 1)
    }

    @Test func deleteTwoWordsWithCount() {
        let (e1, t1) = makeEngine("one two three four", caret: 0)
        send(e1, "d2w")
        #expect(t1.s == "three four")
        let (e2, t2) = makeEngine("one two three four", caret: 0)
        send(e2, "2dw")
        #expect(t2.s == "three four")
    }

    @Test func deleteToLineEndStopsAtNewline() {
        let (e, t) = makeEngine("one two\nnext", caret: 4)
        send(e, "dw") // dw on last word of line: to line end only
        #expect(t.s == "one \nnext")
    }

    @Test func deleteLines() {
        let (e, t) = makeEngine("one\ntwo\nthree", caret: 5)
        send(e, "dd")
        #expect(t.s == "one\nthree")
        send(e, "u")
        #expect(t.s == "one\ntwo\nthree")
    }

    @Test func deleteTwoLines() {
        let (e, t) = makeEngine("one\ntwo\nthree\nfour", caret: 0)
        send(e, "2dd")
        #expect(t.s == "three\nfour")
    }

    @Test func deleteLinewiseWithJ() {
        let (e, t) = makeEngine("one\ntwo\nthree", caret: 1)
        send(e, "dj")
        #expect(t.s == "three")
    }

    @Test func dollarAndDAlias() {
        let (e, t) = makeEngine("hello world", caret: 6)
        send(e, "D")
        #expect(t.s == "hello ")
    }

    @Test func changeWordActsLikeCE() {
        let (e, t) = makeEngine("hello world", caret: 0)
        send(e, "cw")
        #expect(t.s == " world") // 'hello' gone, space kept (ce semantics)
        #expect(e.mode == .insert)
        type(e, t, "hey")
        send(e, "\u{1B}")
        #expect(t.s == "hey world")
        #expect(e.mode == .normal)
        #expect(t.undoDepth == 1) // whole cw+typing is one undo step
        send(e, "u")
        #expect(t.s == "hello world")
    }

    @Test func changeLineKeepsLine() {
        let (e, t) = makeEngine("one\ntwo\nthree", caret: 4)
        send(e, "cc")
        #expect(t.s == "one\n\nthree")
        #expect(e.mode == .insert)
        type(e, t, "TWO")
        send(e, "\u{1B}")
        #expect(t.s == "one\nTWO\nthree")
    }

    @Test func yankAndPasteLinewise() {
        let (e, t) = makeEngine("one\ntwo\nthree", caret: 0)
        send(e, "yy")
        #expect(t.s == "one\ntwo\nthree") // unchanged
        send(e, "p")
        #expect(t.s == "one\none\ntwo\nthree")
        #expect(t.caret == 4)
    }

    @Test func yankWordPasteCharwise() {
        let (e, t) = makeEngine("one two", caret: 0)
        send(e, "yw")
        send(e, "$")
        send(e, "p")
        #expect(t.s == "one twoone ")
    }

    @Test func pasteBeforeLinewise() {
        let (e, t) = makeEngine("aaa\nbbb", caret: 4)
        send(e, "yy") // yanks bbb
        send(e, "P")
        #expect(t.s == "aaa\nbbb\nbbb")
    }
}

// MARK: - Text objects

@MainActor
@Suite struct TextObjectTests {
    @Test func deleteInnerWord() {
        let (e, t) = makeEngine("say hello world", caret: 6)
        send(e, "diw")
        #expect(t.s == "say  world")
    }

    @Test func deleteAroundWord() {
        let (e, t) = makeEngine("say hello world", caret: 6)
        send(e, "daw")
        #expect(t.s == "say world")
    }

    @Test func changeInnerQuotes() {
        let (e, t) = makeEngine("let x = \"hello\" here", caret: 10)
        send(e, "ci\"")
        #expect(t.s == "let x = \"\" here")
        #expect(e.mode == .insert)
        type(e, t, "bye")
        send(e, "\u{1B}")
        #expect(t.s == "let x = \"bye\" here")
    }

    @Test func deleteInnerParens() {
        let (e, t) = makeEngine("call(a, b(c), d) end", caret: 8)
        send(e, "di(")
        #expect(t.s == "call() end")
    }

    @Test func deleteAroundBrackets() {
        let (e, t) = makeEngine("x [1, 2, 3] y", caret: 5)
        send(e, "da[")
        #expect(t.s == "x  y")
    }

    @Test func deleteInnerParagraph() {
        let (e, t) = makeEngine("one\ntwo\n\nthree\nfour\n\nfive", caret: 9)
        send(e, "dip")
        #expect(t.s == "one\ntwo\n\n\nfive")
    }

    @Test func deleteInnerTag() {
        let (e, t) = makeEngine("<div>hello <b>bold</b> end</div>", caret: 15)
        send(e, "dit")
        #expect(t.s == "<div>hello <b></b> end</div>")
    }

    @Test func visualInnerWordDelete() {
        let (e, t) = makeEngine("say hello world", caret: 5)
        send(e, "viwd")
        #expect(t.s == "say  world")
    }
}

// MARK: - Simple edits

@MainActor
@Suite struct EditTests {
    @Test func xDeletesChars() {
        let (e, t) = makeEngine("abcdef", caret: 1)
        send(e, "x")
        #expect(t.s == "acdef")
        send(e, "2x")
        #expect(t.s == "aef")
        send(e, "X")
        #expect(t.s == "ef")
    }

    @Test func replaceChar() {
        let (e, t) = makeEngine("cat", caret: 0)
        send(e, "rb")
        #expect(t.s == "bat")
        #expect(t.caret == 0)
    }

    @Test func toggleCase() {
        let (e, t) = makeEngine("aBc", caret: 0)
        send(e, "3~")
        #expect(t.s == "AbC")
    }

    @Test func joinLines() {
        let (e, t) = makeEngine("one\n    two\nthree", caret: 0)
        send(e, "J")
        #expect(t.s == "one two\nthree")
        #expect(t.caret == 3)
    }

    @Test func openBelowAndAbove() {
        let (e, t) = makeEngine("one\ntwo", caret: 0)
        send(e, "o")
        #expect(t.s == "one\n\ntwo")
        #expect(e.mode == .insert)
        type(e, t, "mid")
        send(e, "\u{1B}")
        #expect(t.s == "one\nmid\ntwo")
        send(e, "O")
        type(e, t, "up")
        send(e, "\u{1B}")
        #expect(t.s == "one\nup\nmid\ntwo")
        #expect(t.undoDepth == 2) // o+typing = 1, O+typing = 1
    }

    @Test func insertVariants() {
        let (e, t) = makeEngine("  word", caret: 4)
        send(e, "I")
        #expect(t.caret == 2)
        send(e, "\u{1B}")
        send(e, "A")
        #expect(t.caret == 6)
        #expect(e.mode == .insert)
        send(e, "\u{1B}")
        send(e, "a")
        #expect(e.mode == .insert)
        #expect(t.caret == 6)
    }

    @Test func substituteChar() {
        let (e, t) = makeEngine("cat", caret: 0)
        send(e, "s")
        #expect(t.s == "at")
        #expect(e.mode == .insert)
        type(e, t, "b")
        send(e, "\u{1B}")
        #expect(t.s == "bat")
    }
}

// MARK: - Visual mode

@MainActor
@Suite struct VisualTests {
    @Test func charwiseSelectAndDelete() {
        let (e, t) = makeEngine("hello world", caret: 0)
        send(e, "ve")
        #expect(t.selection == NSRange(location: 0, length: 5))
        send(e, "d")
        #expect(t.s == " world")
        #expect(e.mode == .normal)
    }

    @Test func linewiseSelectAndYank() {
        let (e, t) = makeEngine("one\ntwo\nthree", caret: 0)
        send(e, "Vjy")
        send(e, "G")
        send(e, "p")
        #expect(t.s == "one\ntwo\nthree\none\ntwo")
    }

    @Test func visualChange() {
        let (e, t) = makeEngine("hello world", caret: 0)
        send(e, "vec")
        #expect(e.mode == .insert)
        type(e, t, "bye")
        send(e, "\u{1B}")
        #expect(t.s == "bye world")
    }

    @Test func visualToggleCollapsesSelection() {
        let (e, t) = makeEngine("hello", caret: 0)
        send(e, "vl") // select "he", head on 'e'
        #expect(t.selection == NSRange(location: 0, length: 2))
        send(e, "v") // toggle off → collapse to head, nothing stays highlighted
        #expect(e.mode == .normal)
        #expect(t.selection == NSRange(location: 1, length: 0))
    }

    /// The caret renderer reads displayCaret synchronously while the selection
    /// is being assigned — the head must already be current at that moment
    /// (regression: block caret painted at the previous session's head).
    @Test func displayCaretIsCurrentAtSelectionTime() {
        let (e, t) = makeEngine("abcdef\nghijkl", caret: 0)
        send(e, "vll\u{1B}") // first visual session, head ends at 2
        send(e, "j")         // move away (caret line 2)

        var observed: [Int] = []
        t.selectionObserver = { observed.append(e.displayCaret) }
        send(e, "v") // new session: at assignment time head must be the caret…
        send(e, "l") // …and track motions immediately
        t.selectionObserver = nil

        let head = t.selection.location + max(t.selection.length - 1, 0)
        #expect(observed.last == head)
        #expect(!observed.contains(2)) // never the stale head from session one
    }

    @Test func escapeCollapsesToCaret() {
        let (e, t) = makeEngine("hello", caret: 0)
        send(e, "vll")
        #expect(t.selection.length == 3)
        send(e, "\u{1B}")
        #expect(t.selection.length == 0)
        #expect(e.mode == .normal)
    }
}

// MARK: - Undo / redo / dot

@MainActor
@Suite struct UndoDotTests {
    @Test func halfPageScroll() {
        let doc = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let (e, t) = makeEngine(doc, caret: 0)
        _ = e.handleKey(VimKey(characters: "d", hasControl: true))
        // visibleLineCount 20 → half page = 10 lines down.
        #expect(t.caret == (doc as NSString).range(of: "line 11").location)
        _ = e.handleKey(VimKey(characters: "u", hasControl: true))
        #expect(t.caret == 0)
    }

    @Test func undoRedo() {
        let (e, t) = makeEngine("one two", caret: 0)
        send(e, "dw")
        #expect(t.s == "two")
        send(e, "u")
        #expect(t.s == "one two")
        _ = e.handleKey(VimKey(characters: "r", hasControl: true))
        #expect(t.s == "two")
    }

    @Test func dotRepeatsDelete() {
        let (e, t) = makeEngine("one two three", caret: 0)
        send(e, "dw")
        #expect(t.s == "two three")
        send(e, ".")
        #expect(t.s == "three")
    }

    @Test func dotRepeatsChangeWithTypedText() {
        let (e, t) = makeEngine("aaa bbb ccc", caret: 0)
        send(e, "ciw")
        type(e, t, "X")
        send(e, "\u{1B}")
        #expect(t.s == "X bbb ccc")
        send(e, "w") // to bbb
        send(e, ".")
        #expect(t.s == "X X ccc")
    }

    @Test func dotRepeatsX() {
        let (e, t) = makeEngine("abcdef", caret: 0)
        send(e, "2x")
        #expect(t.s == "cdef")
        send(e, ".")
        #expect(t.s == "ef")
    }
}

// MARK: - Search

@MainActor
@Suite struct SearchTests {
    @Test func slashSearchJumps() {
        let (e, t) = makeEngine("alpha beta gamma beta", caret: 0)
        send(e, "/beta\n")
        #expect(t.selection == NSRange(location: 6, length: 4))
        send(e, "n")
        #expect(t.selection == NSRange(location: 17, length: 4))
        send(e, "n") // wraps
        #expect(t.selection == NSRange(location: 6, length: 4))
        send(e, "N")
        #expect(t.selection == NSRange(location: 17, length: 4))
    }

    @Test func smartcase() {
        let (e, t) = makeEngine("Foo foo", caret: 0)
        send(e, "/foo\n") // lowercase → case-insensitive → finds "foo" at 4? No: from caret+1, "Foo" at 0 excluded, oo... matches at 4
        #expect(t.selection == NSRange(location: 4, length: 3))
        send(e, "gg")
        send(e, "/Foo\n") // has uppercase → case-sensitive
        #expect(t.selection == NSRange(location: 0, length: 3))
    }

    @Test func hashSearchesWordUnderCaretBackward() {
        let (e, t) = makeEngine("alpha beta alpha gamma alpha", caret: 25) // last alpha
        send(e, "#")
        #expect(t.selection.location == 11) // middle occurrence
        send(e, "n") // continues backward
        #expect(t.selection.location == 0)
        send(e, "N") // opposite: forward
        #expect(t.selection.location == 11)
    }

    @Test func starSearchesForwardWholeWord() {
        let (e, t) = makeEngine("foo foobar foo", caret: 0)
        send(e, "*")
        #expect(t.selection.location == 11) // skips foobar (word-bounded)
        send(e, "n") // wraps
        #expect(t.selection.location == 0)
    }

    @Test func starFromPunctuationUsesNextWord() {
        let (e, t) = makeEngine("-- token and token again", caret: 0)
        send(e, "*") // caret on '-': vim takes the next word on the line
        #expect(t.selection.location == 13)
    }

    @Test func colonGoesToLine() {
        let (e, t) = makeEngine("one\ntwo\nthree\nfour", caret: 0)
        send(e, ":3\n")
        #expect(t.caret == 8) // first char of "three"
        #expect(e.mode == .normal)
    }

    @Test func colonSignalsCommandModeAndCancels() {
        let (e, t) = makeEngine("one\ntwo\nthree", caret: 0)
        var states: [Bool] = []
        e.onCommandMode = { states.append($0) }
        send(e, ":12")
        #expect(states == [true])
        send(e, "\u{1B}")
        #expect(states == [true, false])
        #expect(t.caret == 0) // cancel moves nothing
        send(e, ":2\n")
        #expect(states == [true, false, true, false])
        #expect(t.caret == 4)
    }

    @Test func escapeCancelsSearch() {
        let (e, t) = makeEngine("hello", caret: 0)
        send(e, "/hel\u{1B}")
        #expect(t.caret == 0)
        // engine back to normal command handling
        send(e, "ll")
        #expect(t.caret == 2)
    }
}
