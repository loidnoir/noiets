import Foundation
import VaultStore

extension NoteIndex {
    public enum QuickOpenDestination: Equatable, Sendable {
        case view(SavedView)
        case note(NoteRow)
    }

    /// Saved queries lead matching documents, including exact-name collisions.
    /// The note-only matcher remains unchanged for wiki-link completion.
    public func quickOpenDestinations(_ query: String, views: [SavedView], limit: Int = 30) throws -> [QuickOpenDestination] {
        guard limit > 0 else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = views.enumerated().filter { q.isEmpty || $0.element.name.localizedCaseInsensitiveContains(q) }
            .sorted { lhs, rhs in
                func rank(_ name: String) -> Int {
                    let name = name.lowercased()
                    return name == q ? 0 : name.hasPrefix(q) ? 1 : 2
                }
                let left = rank(lhs.element.name), right = rank(rhs.element.name)
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }.prefix(limit).map { QuickOpenDestination.view($0.element) }
        let remaining = limit - matches.count
        guard remaining > 0 else { return matches }
        return matches + (try quickOpen(query, limit: remaining)).map { .note($0) }
    }
}
