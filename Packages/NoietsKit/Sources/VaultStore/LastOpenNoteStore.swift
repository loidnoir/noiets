import Foundation

/// Device-local navigation state, separate from note files and vault metadata.
/// Each vault remembers its own last successfully opened Markdown note.
public enum LastOpenNoteStore {
    static func preferenceKey(for vault: Vault) -> String {
        "lastOpenNote." + vault.rootURL.path
    }

    private static func relativePath(of note: URL, in vault: Vault) -> String? {
        guard note.isFileURL, vault.rootURL.isFileURL, Vault.isMarkdownFile(note) else { return nil }
        let root = vault.rootURL.pathComponents
        let components = note.standardizedFileURL.pathComponents
        guard components.count > root.count, Array(components.prefix(root.count)) == root else { return nil }
        let relative = components.dropFirst(root.count).joined(separator: "/")
        return Vault.hasHiddenComponent(relative) ? nil : relative
    }

    public static func save(_ note: URL?, vault: Vault, defaults: UserDefaults = .standard) {
        let key = preferenceKey(for: vault)
        guard let note else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let relative = relativePath(of: note, in: vault) else { return }
        if defaults.string(forKey: key) != relative { defaults.set(relative, forKey: key) }
    }

    /// Stale, malformed, hidden, and non-note destinations are never restored.
    public static func load(vault: Vault, defaults: UserDefaults = .standard) -> URL? {
        guard let relative = defaults.string(forKey: preferenceKey(for: vault)),
              !relative.isEmpty, !relative.hasPrefix("/"), !Vault.hasHiddenComponent(relative) else { return nil }
        let note = vault.rootURL.appendingPathComponent(relative).standardizedFileURL
        guard relativePath(of: note, in: vault) != nil else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: note.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: note.path) else { return nil }
        return note
    }
}
