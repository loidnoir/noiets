import Foundation

/// Persists which notes are locked for writing, as `.noiets/locks.json`
/// inside the project — an ordered array of rel-paths. Lives with the
/// project folder, so locks survive reinstalls and sync with the notes.
public enum LocksStore {
    private static func fileURL(_ vault: Vault) -> URL {
        vault.rootURL
            .appendingPathComponent(".noiets", isDirectory: true)
            .appendingPathComponent("locks.json")
    }

    public static func load(vault: Vault) -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL(vault)) else { return [] }
        return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    public static func save(_ locks: Set<String>, vault: Vault) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(locks.sorted()) else { return }
        let url = fileURL(vault)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }

    public static func setLocked(_ relPath: String, _ locked: Bool, vault: Vault) {
        var locks = load(vault: vault)
        if locked { locks.insert(relPath) } else { locks.remove(relPath) }
        save(locks, vault: vault)
    }
}
