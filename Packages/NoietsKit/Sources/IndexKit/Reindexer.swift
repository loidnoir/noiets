import Foundation
import VaultStore

/// Serializes all index writes: debounced incremental updates from file
/// events, plus the launch-time reconciliation that makes the index self-heal
/// against anything that happened while the app wasn't running.
public actor Reindexer {
    private let index: NoteIndex
    private let vault: Vault
    private var pendingRelPaths = Set<String>()
    private var flushTask: Task<Void, Never>?

    /// Fired on the main actor after any batch of index changes lands.
    private let onIndexChanged: @MainActor @Sendable () -> Void

    public init(index: NoteIndex, onIndexChanged: @escaping @MainActor @Sendable () -> Void) {
        self.index = index
        self.vault = index.vault
        self.onIndexChanged = onIndexChanged
    }

    // MARK: Incremental updates

    /// Report changed absolute paths (from FSEvents or our own saves).
    public func pathsChanged(_ absolutePaths: [String]) {
        let fm = FileManager.default
        for path in absolutePaths {
            let url = URL(fileURLWithPath: path)
            // App-internal dot locations (.trash, .noiets) are never notes:
            // don't index their markdown and don't let their churn (views.json
            // saves, trash moves) force full reconciles.
            if Vault.hasHiddenComponent(vault.relativePath(of: url)) { continue }
            if Vault.isMarkdownFile(url) {
                pendingRelPaths.insert(vault.relativePath(of: url))
                continue
            }
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
            if !exists || isDir.boolValue {
                // A folder changed or something vanished (rename/move/delete):
                // fall back to a full reconcile pass.
                pendingRelPaths.insert("") // sentinel
            }
            // Existing non-markdown files (.DS_Store & friends): ignore.
        }
        if !pendingRelPaths.isEmpty { scheduleFlush() }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        let batch = pendingRelPaths
        pendingRelPaths.removeAll()
        guard !batch.isEmpty else { return }

        if batch.contains("") {
            await reconcile()
            return
        }
        for relPath in batch {
            reindexOne(relPath: relPath)
        }
        try? index.resolveLinks()
        await onIndexChanged()
    }

    private func reindexOne(relPath: String) {
        let url = vault.rootURL.appendingPathComponent(relPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try? index.deleteNote(relPath: relPath)
            return
        }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let text = try? NoteIO.read(url) else { return }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let created = (attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? mtime
        let size = (attrs[.size] as? Int) ?? 0
        let fallback = url.deletingPathExtension().lastPathComponent
        let extracted = NoteExtractor.extract(markdown: text, fallbackTitle: fallback)
        try? index.upsert(relPath: relPath, extracted: extracted,
                          mtime: mtime, size: size, created: created)
    }

    // MARK: Reconciliation (launch + fallback)

    /// Walk the vault, upsert anything new/changed (by mtime+size), delete
    /// index rows whose files vanished. The index heals from any state.
    public func reconcile() async {
        let known: [String: (mtime: Double, size: Int)] = (try? index.allNotes())
            .map { rows in
                Dictionary(uniqueKeysWithValues: rows.map { ($0.relPath, ($0.mtime, $0.size)) })
            } ?? [:]

        let onDisk = Self.walkVault(root: vault.rootURL, vault: vault)
        var seen = Set<String>()
        for entry in onDisk {
            seen.insert(entry.relPath)
            if let existing = known[entry.relPath],
               abs(existing.mtime - entry.mtime) < 0.001, existing.size == entry.size {
                continue // unchanged
            }
            reindexOne(relPath: entry.relPath)
        }

        // Remove orphans.
        for relPath in known.keys where !seen.contains(relPath) {
            try? index.deleteNote(relPath: relPath)
        }

        try? index.resolveLinks()
        await onIndexChanged()
    }

    /// Synchronous vault walk (DirectoryEnumerator can't be iterated from an
    /// async context under Swift 6).
    private static func walkVault(root: URL, vault: Vault) -> [(relPath: String, mtime: Double, size: Int)] {
        let fm = FileManager.default
        var result: [(String, Double, Int)] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            guard Vault.isMarkdownFile(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            result.append((
                vault.relativePath(of: url),
                values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                values?.fileSize ?? 0
            ))
        }
        return result
    }
}
