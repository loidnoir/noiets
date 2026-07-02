import Foundation

/// Ends-diff over block-structure signatures: given the per-line structure IDs
/// before and after an edit, returns the span of (new) line indices whose
/// block structure may have changed. Typing inside a paragraph yields an empty
/// span; toggling a code fence yields everything below it.
public enum SignatureDiff {
    public static func changedLineSpan(old: [Int], new: [Int]) -> Range<Int> {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        return prefix..<(new.count - suffix)
    }
}
