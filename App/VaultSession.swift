import AppKit
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
    var onTreeChange: (() -> Void)?

    private(set) var currentNoteURL: URL?
    private var pendingText: (@MainActor () -> String)?
    private var saveWork: DispatchWorkItem?

    init(vault: Vault) {
        self.vault = vault
        self.tree = VaultScanner.scan(vault)
    }

    // MARK: Tree

    func rescan() {
        tree = VaultScanner.scan(vault)
        onTreeChange?()
    }

    func firstNote() -> URL? {
        func walk(_ node: FileNode) -> URL? {
            for child in node.children {
                if !child.isFolder { return child.url }
                if let found = walk(child) { return found }
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
        } catch {
            Self.log.error("Save failed for \(url.path): \(error.localizedDescription)")
            NSSound.beep()
        }
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
