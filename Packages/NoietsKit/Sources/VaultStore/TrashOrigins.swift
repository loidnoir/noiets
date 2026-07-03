import Foundation

/// Sidecar map inside `.trash` recording where each trashed item came from
/// (vault-relative folder), so restore can put it back. Loss-safe: a missing
/// entry just restores to the vault root.
public enum TrashOrigins {
    private static func indexURL(_ vault: Vault) -> URL {
        vault.trashURL.appendingPathComponent(".origins.json")
    }

    private static func load(_ vault: Vault) -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL(vault)) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func save(_ map: [String: String], _ vault: Vault) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: indexURL(vault), options: [.atomic])
    }

    /// Records that the trashed item `name` came from `originFolder`
    /// (vault-relative; "" is the root).
    public static func record(name: String, originFolder: String, vault: Vault) {
        var map = load(vault)
        map[name] = originFolder
        save(map, vault)
    }

    /// Vault-relative folder the item was trashed from, if known.
    public static func origin(name: String, vault: Vault) -> String? {
        load(vault)[name]
    }

    public static func forget(name: String, vault: Vault) {
        var map = load(vault)
        guard map.removeValue(forKey: name) != nil else { return }
        save(map, vault)
    }
}
