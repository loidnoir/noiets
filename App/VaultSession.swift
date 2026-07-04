import AppKit
import IndexKit
import VaultStore
import os

/// App-level vault coordinator: owns the current vault, its scanned tree, the
/// currently open note, and the debounced autosave pipeline. The only path by
/// which the app writes note files.
@MainActor
final class VaultSession {
    private static let log = Logger(subsystem: "com.noiets", category: "vault")

    let vault: Vault
    private(set) var tree: FileNode
    /// Multicast: sidebar tree, trash view, … all react to vault changes.
    private var treeObservers: [() -> Void] = []

    func onTreeChange(_ observer: @escaping () -> Void) {
        treeObservers.append(observer)
    }

    /// Saved sidebar views (NoQL queries) — persisted in the vault.
    private(set) var savedViews: [SavedView] = []
    private var viewObservers: [() -> Void] = []

    /// Notes locked for writing (rel-paths) — persisted in the vault.
    private(set) var lockedRelPaths: Set<String> = []

    func onViewsChange(_ observer: @escaping () -> Void) {
        viewObservers.append(observer)
    }
    /// Fired after any index batch lands (search/backlink UIs refresh).
    var onIndexChanged: (() -> Void)?

    // Derived, rebuildable index (nil only if SQLite setup failed).
    private(set) var index: NoteIndex?
    private var reindexer: Reindexer?
    private var watcher: FSEventsWatcher?
    private var treeRescanWork: DispatchWorkItem?

    private(set) var currentNoteURL: URL?
    private var pendingText: (@MainActor () -> String)?
    private var saveWork: DispatchWorkItem?

    init(vault: Vault) {
        self.vault = vault
        self.tree = VaultScanner.scan(vault)
        self.savedViews = ViewsStore.load(vault: vault)
        self.lockedRelPaths = LocksStore.load(vault: vault)
    }

    // MARK: Locks

    func isLocked(_ url: URL) -> Bool {
        lockedRelPaths.contains(vault.relativePath(of: url))
    }

    func setLocked(_ url: URL, _ locked: Bool) {
        let relPath = vault.relativePath(of: url)
        LocksStore.setLocked(relPath, locked, vault: vault)
        lockedRelPaths = LocksStore.load(vault: vault)
    }

    // MARK: Saved views

    private func notifyViewObservers() {
        for observer in viewObservers {
            observer()
        }
    }

    func upsertView(name: String, query: String) {
        ViewsStore.upsert(name: name, query: query, vault: vault)
        savedViews = ViewsStore.load(vault: vault)
        notifyViewObservers()
    }

    @discardableResult
    func renameView(_ old: String, to new: String) -> Bool {
        guard ViewsStore.rename(old, to: new, vault: vault) else { return false }
        savedViews = ViewsStore.load(vault: vault)
        notifyViewObservers()
        return true
    }

    func deleteView(named name: String) {
        ViewsStore.delete(name: name, vault: vault)
        savedViews = ViewsStore.load(vault: vault)
        notifyViewObservers()
    }

    /// Boots the index + file watching. Called once the UI is up.
    func startIndexing() {
        do {
            let index = try NoteIndex(vault: vault)
            self.index = index
            let reindexer = Reindexer(index: index) { [weak self] in
                self?.onIndexChanged?()
            }
            self.reindexer = reindexer

            let watcher = FSEventsWatcher(root: vault.rootURL) { [weak self] paths in
                Task { @MainActor [weak self] in
                    self?.fileSystemChanged(paths: paths)
                }
            }
            watcher.start()
            self.watcher = watcher

            Task { await reindexer.reconcile() }
        } catch {
            Self.log.error("Index setup failed: \(error.localizedDescription)")
        }
    }

    private func fileSystemChanged(paths: [String]) {
        // Keep the sidebar tree fresh (Finder renames/moves), debounced.
        treeRescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        treeRescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)

        if let reindexer {
            Task { await reindexer.pathsChanged(paths) }
        }
    }

    // MARK: Tree

    func rescan() {
        tree = VaultScanner.scan(vault)
        for observer in treeObservers {
            observer()
        }
        // views.json / locks.json may have been edited externally (git pull).
        let fresh = ViewsStore.load(vault: vault)
        if fresh != savedViews {
            savedViews = fresh
            notifyViewObservers()
        }
        lockedRelPaths = LocksStore.load(vault: vault)
    }

    func firstNote() -> URL? {
        func walk(_ node: FileNode) -> URL? {
            for child in node.children {
                // Images are tree leaves too — a "note" is markdown only.
                if !child.isFolder, Vault.isMarkdownFile(child.url) { return child.url }
                if child.isFolder, let found = walk(child) { return found }
            }
            return nil
        }
        return walk(tree)
    }

    // MARK: Open / edit / save

    func readNote(at url: URL) -> String? {
        try? NoteIO.read(url)
    }

    /// Call when the editor switches to a note (flushes the previous one first).
    func noteOpened(_ url: URL) {
        flushPendingSave()
        currentNoteURL = url
    }

    /// Called on every editor change; the text provider is pulled lazily at
    /// save time so keystrokes stay O(1).
    func noteEdited(textProvider: @escaping @MainActor () -> String) {
        guard currentNoteURL != nil else { return }
        pendingText = textProvider
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func flushPendingSave() {
        saveWork?.cancel()
        saveWork = nil
        saveNow()
    }

    private func saveNow() {
        guard let url = currentNoteURL, let provider = pendingText else { return }
        pendingText = nil
        do {
            try NoteIO.write(provider(), to: url)
            if let reindexer {
                Task { await reindexer.pathsChanged([url.path]) } // fresh index now
            }
        } catch {
            Self.log.error("Save failed for \(url.path): \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    func url(forRelPath relPath: String) -> URL {
        vault.rootURL.appendingPathComponent(relPath)
    }

    /// Filename-stem match against the live tree — the create-on-missing
    /// safety net while the index is still warming up after launch.
    func noteInTree(matching target: String) -> URL? {
        let lowered = target.lowercased()
        func walk(_ node: FileNode) -> URL? {
            for child in node.children {
                if child.isFolder {
                    if let found = walk(child) { return found }
                } else if child.title.lowercased() == lowered {
                    return child.url
                }
            }
            return nil
        }
        return walk(tree)
    }

    // MARK: Mutations

    @discardableResult
    func createNote(in folder: URL?) -> URL? {
        do {
            let url = try NoteIO.createNote(in: folder ?? vault.rootURL)
            rescan()
            return url
        } catch {
            Self.log.error("Create note failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func createFolder(in parent: URL?) -> URL? {
        let fm = FileManager.default
        let base = parent ?? vault.rootURL
        var url = base.appendingPathComponent("Untitled Folder", isDirectory: true)
        var counter = 2
        while fm.fileExists(atPath: url.path) {
            url = base.appendingPathComponent("Untitled Folder \(counter)", isDirectory: true)
            counter += 1
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            rescan()
            return url
        } catch {
            Self.log.error("Create folder failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Moves a note or folder into another folder (drag & drop). Returns the
    /// destination URL, or nil for no-ops/failures. Keeps the open note's
    /// identity intact across the move.
    @discardableResult
    func moveItem(at url: URL, into folder: URL) -> URL? {
        let fm = FileManager.default
        let source = url.standardizedFileURL
        var dest = folder.appendingPathComponent(url.lastPathComponent)
        guard dest.standardizedFileURL != source,
              source.deletingLastPathComponent() != folder.standardizedFileURL else { return nil }

        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while fm.fileExists(atPath: dest.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            dest = folder.appendingPathComponent(name)
            counter += 1
        }
        do {
            try fm.moveItem(at: url, to: dest)
        } catch {
            Self.log.error("Move failed: \(error.localizedDescription)")
            return nil
        }

        // Re-point the open note if it (or its containing folder) moved —
        // otherwise the next autosave would resurrect the old path.
        if let current = currentNoteURL {
            if current.standardizedFileURL == source {
                currentNoteURL = dest
            } else if current.path.hasPrefix(source.path + "/") {
                let suffix = String(current.path.dropFirst(source.path.count))
                currentNoteURL = URL(fileURLWithPath: dest.path + suffix)
            }
        }

        rescan()
        if let reindexer {
            Task { await reindexer.pathsChanged([source.path, dest.path]) }
        }
        return dest
    }

    /// Renames a note or folder in place (extension preserved for files).
    /// Returns the new URL, or nil on collision/failure.
    @discardableResult
    func rename(_ url: URL, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return nil }
        let fm = FileManager.default
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let ext = url.pathExtension
        let name = isFolder || ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        guard dest.standardizedFileURL != url.standardizedFileURL else { return url }
        guard !fm.fileExists(atPath: dest.path) else { return nil }
        do {
            try fm.moveItem(at: url, to: dest)
        } catch {
            Self.log.error("Rename failed: \(error.localizedDescription)")
            return nil
        }
        let source = url.standardizedFileURL
        if let current = currentNoteURL {
            if current.standardizedFileURL == source {
                currentNoteURL = dest
            } else if current.path.hasPrefix(source.path + "/") {
                let suffix = String(current.path.dropFirst(source.path.count))
                currentNoteURL = URL(fileURLWithPath: dest.path + suffix)
            }
        }
        rescan()
        if let reindexer {
            Task { await reindexer.pathsChanged([source.path, dest.path]) }
        }
        return dest
    }

    /// All folders in the vault (for the move picker), root first.
    func allFolders() -> [(title: String, url: URL)] {
        var result: [(String, URL)] = [(vault.name, vault.rootURL)]
        func walk(_ node: FileNode, path: String) {
            for child in node.children where child.isFolder {
                let display = path.isEmpty ? child.title : "\(path)/\(child.title)"
                result.append((display, child.url))
                walk(child, path: display)
            }
        }
        walk(tree, path: "")
        return result
    }

    func trashNote(_ url: URL) {
        let removesCurrent = currentNoteURL == url
            || currentNoteURL?.path.hasPrefix(url.path + "/") == true
        if removesCurrent {
            saveWork?.cancel()
            saveWork = nil
            pendingText = nil
            currentNoteURL = nil
        }
        do {
            try NoteIO.moveToTrash(url, vault: vault)
        } catch {
            Self.log.error("Trash failed: \(error.localizedDescription)")
        }
        rescan()
    }

    // MARK: First-run content

    func seedWelcomeNoteIfEmpty() {
        guard firstNote() == nil else { return }
        let url = vault.rootURL.appendingPathComponent("Welcome to Noiets.md")
        try? NoteIO.write(WelcomeNote.markdown, to: url)
        rescan()
    }
}
