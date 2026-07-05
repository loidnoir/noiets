import Foundation

/// Reading and atomic writing of note files. The only writer of vault content.
public enum NoteIO {
    /// Reads a note as UTF-8, normalizing CRLF/CR to LF so the editor and all
    /// source ranges operate on a single newline convention.
    public static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let raw = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self) // lossy fallback
        if raw.contains("\r") {
            return raw.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        return raw
    }

    /// Atomic write that preserves the file's creation date across the
    /// temp-file-rename dance.
    public static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let creation = (try? fm.attributesOfItem(atPath: url.path)[.creationDate]) as? Date
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: [.atomic])
        if let creation {
            try? fm.setAttributes([.creationDate: creation], ofItemAtPath: url.path)
        }
    }

    /// Moves a note (or folder) to the vault's `.trash` folder, keeping the name
    /// unique. Returns the destination URL.
    @discardableResult
    public static func moveToTrash(_ url: URL, vault: Vault) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: vault.trashURL, withIntermediateDirectories: true)
        var dest = vault.trashURL.appendingPathComponent(url.lastPathComponent)
        var counter = 2
        while fm.fileExists(atPath: dest.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            dest = vault.trashURL.appendingPathComponent(name)
            counter += 1
        }
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    /// Moves a trashed item back to `originFolder` (vault-relative) when that
    /// folder still exists, else the vault root. Returns the restored URL.
    @discardableResult
    public static func restoreFromTrash(_ url: URL, vault: Vault, originFolder: String?) throws -> URL {
        let fm = FileManager.default
        var targetDir = vault.rootURL
        if let rel = originFolder, !rel.isEmpty {
            let candidate = vault.rootURL.appendingPathComponent(rel, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                targetDir = candidate
            }
        }
        var dest = targetDir.appendingPathComponent(url.lastPathComponent)
        var counter = 2
        while fm.fileExists(atPath: dest.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            dest = targetDir.appendingPathComponent(name)
            counter += 1
        }
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    /// Creates a uniquely-named new note in `folder`, returning its URL.
    public static func createNote(in folder: URL, baseName: String = "Untitled", contents: String = "") throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(baseName).md")
        var counter = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(baseName) \(counter).md")
            counter += 1
        }
        try write(contents, to: url)
        return url
    }
}
