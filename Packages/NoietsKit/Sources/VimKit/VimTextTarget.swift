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
}
