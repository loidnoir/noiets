import Foundation

/// A saved sidebar view: a named NoQL filter query over the vault's notes.
public struct SavedView: Codable, Equatable, Sendable {
    public var name: String
    public var query: String

    public init(name: String, query: String) {
        self.name = name
        self.query = query
    }
}

/// Persists saved views as `<vault>/.noiets/views.json` — an ordered, pretty
/// JSON array that travels with the vault (git/iCloud) and is human-editable.
/// Loss-safe: missing or corrupt file reads as no saved views.
public enum ViewsStore {
    private static func fileURL(_ vault: Vault) -> URL {
        vault.rootURL
            .appendingPathComponent(".noiets", isDirectory: true)
            .appendingPathComponent("views.json")
    }

    public static func load(vault: Vault) -> [SavedView] {
        guard let data = try? Data(contentsOf: fileURL(vault)) else { return [] }
        return (try? JSONDecoder().decode([SavedView].self, from: data)) ?? []
    }

    public static func save(_ views: [SavedView], vault: Vault) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(views) else { return }
        let url = fileURL(vault)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }

    /// Updates the view named `name` in place, or appends a new one.
    public static func upsert(name: String, query: String, vault: Vault) {
        var views = load(vault: vault)
        if let index = views.firstIndex(where: { $0.name == name }) {
            views[index].query = query
        } else {
            views.append(SavedView(name: name, query: query))
        }
        save(views, vault: vault)
    }

    /// Renames a view; false when `old` doesn't exist or `new` already does.
    @discardableResult
    public static func rename(_ old: String, to new: String, vault: Vault) -> Bool {
        var views = load(vault: vault)
        guard let index = views.firstIndex(where: { $0.name == old }),
              !views.contains(where: { $0.name == new }) else { return false }
        views[index].name = new
        save(views, vault: vault)
        return true
    }

    public static func delete(name: String, vault: Vault) {
        var views = load(vault: vault)
        views.removeAll { $0.name == name }
        save(views, vault: vault)
    }
}
