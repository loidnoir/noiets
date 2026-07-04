import Foundation

/// A vault is a folder of markdown files. The filesystem is the source of truth.
public struct Vault: Hashable, Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public var name: String { rootURL.lastPathComponent }

    /// Obsidian-compatible in-vault trash folder.
    public var trashURL: URL { rootURL.appendingPathComponent(".trash", isDirectory: true) }

    public func relativePath(of url: URL) -> String {
        let root = rootURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func isMarkdownFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// True when any path component is dot-prefixed (.trash, .noiets, …) —
    /// app-internal locations the indexer must never treat as notes.
    public static func hasHiddenComponent(_ relPath: String) -> Bool {
        relPath.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Image assets are shown in the tree (openable, embeddable) but never
    /// indexed — only markdown files are notes.
    public static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    public static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }
}
