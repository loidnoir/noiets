import Foundation

/// A node in the vault's folder tree. Reference type so NSOutlineView items keep
/// stable identity within one scan; the tree is rebuilt wholesale on rescan.
public final class FileNode {
    public let url: URL
    public let isFolder: Bool
    public private(set) var children: [FileNode]

    public init(url: URL, isFolder: Bool, children: [FileNode] = []) {
        self.url = url.standardizedFileURL
        self.isFolder = isFolder
        self.children = children
    }

    /// Display name: filename without the .md extension for files.
    public var title: String {
        isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}

public enum VaultScanner {
    /// Scans the vault into a tree of folders + markdown files.
    /// Hidden entries (dotfiles, .trash, .obsidian, …) are skipped.
    public static func scan(_ vault: Vault) -> FileNode {
        FileNode(url: vault.rootURL, isFolder: true, children: scanChildren(of: vault.rootURL))
    }

    private static func scanChildren(of dir: URL) -> [FileNode] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var folders: [FileNode] = []
        var files: [FileNode] = []
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                folders.append(FileNode(url: url, isFolder: true, children: scanChildren(of: url)))
            } else if Vault.isMarkdownFile(url) {
                files.append(FileNode(url: url, isFolder: false))
            }
        }
        let sort: (FileNode, FileNode) -> Bool = {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return folders.sorted(by: sort) + files.sorted(by: sort)
    }
}
