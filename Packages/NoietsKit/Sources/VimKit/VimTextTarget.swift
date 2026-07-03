import Foundation

/// The seam between the vim engine and the actual editor. The NSTextView
/// adapter routes `replace` through shouldChangeText → replaceCharacters →
/// didChangeText so undo, highlighting, and autosave all fire exactly as if
/// the user had typed; the test mock is a plain string with snapshots.
@MainActor
public protocol VimTextTarget: AnyObject {
    var text: NSString { get }
    /// Named `selection` (not `selectedRange`) so NSTextView can conform
    /// without clashing with NSText's read-only `selectedRange` property.
    var selection: NSRange { get set }

    /// Apply one edit through the editor's normal change pipeline.
    func replace(_ range: NSRange, with string: String)

    func beginUndoGroup()
    func endUndoGroup()
    func breakUndoCoalescing()
    func performUndo()
    func performRedo()

    func scrollCaretToVisible()

    /// Approximate number of text lines visible in the viewport (for ⌃d/⌃u
    /// half-page motions). Headless targets return a constant.
    func visibleLineCount() -> Int

    /// Moves the caret by visual (soft-wrapped) lines with a pixel-stable
    /// goal column — what j/k feel like on wrapped prose. Positive = down.
    /// The editor delegates to native line movement; headless targets
    /// approximate with logical lines.
    func moveCaretVisually(lines: Int)

    /// Character location of the 1-based visual row (`:N`). Wrapped rows
    /// count individually; headless targets treat rows as logical lines.
    func characterLocation(ofVisualRow row: Int) -> Int?
}
