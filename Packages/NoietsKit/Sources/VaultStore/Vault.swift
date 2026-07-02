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
}
