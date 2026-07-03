import AppKit

/// Loads and caches images referenced from notes.
/// - Local paths resolve against the vault root (absolute and ~ paths work
///   too); bare names fall back to the vault's assets/ folder.
/// - http(s) URLs download once in the background; the completion hook lets
///   the editor re-render the line when the image arrives.
@MainActor
public final class ImageProvider {
    public var rootURL: URL? {
        didSet { filenameIndex = nil }
    }
    /// Folder of the currently open note — markdown-relative paths resolve
    /// against it first (standard markdown semantics).
    public var noteFolderURL: URL?
    /// Fired on the main actor whenever a remote image finishes downloading.
    public var onRemoteImageLoaded: (() -> Void)?

    private var cache: [String: NSImage] = [:]
    private var pendingRemote: Set<String> = []
    private var failedRemote: Set<String> = []
    /// Lazy vault-wide map of image filenames → URLs (Obsidian attachments
    /// can live anywhere: next to the note, attachments/, Files/, …).
    private var filenameIndex: [String: URL]?

    public init() {}

    public func image(forPath path: String) -> NSImage? {
        let trimmed = (path.removingPercentEncoding ?? path)
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let cached = cache[trimmed] { return cached }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            fetchRemote(trimmed)
            return nil // renders as source until the download lands
        }

        if let url = resolveFileURL(forPath: trimmed),
           let image = NSImage(contentsOf: url) {
            store(trimmed, image)
            return image
        }
        return nil
    }

    /// Resolves a (non-remote) image reference to an existing file, checking:
    /// absolute/~ paths, the note's own folder, the vault root, assets/, and
    /// finally a vault-wide filename search.
    public func resolveFileURL(forPath path: String) -> URL? {
        let trimmed = (path.removingPercentEncoding ?? path)
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let fm = FileManager.default

        for candidate in localCandidates(for: trimmed)
        where fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        // Last resort: find the filename anywhere in the vault.
        let filename = (trimmed as NSString).lastPathComponent
        return filenameLookup()[filename.lowercased()]
    }

    private func localCandidates(for path: String) -> [URL] {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return [URL(fileURLWithPath: expanded)]
        }
        var candidates: [URL] = []
        if let noteFolderURL {
            candidates.append(noteFolderURL.appendingPathComponent(path))
        }
        if let rootURL {
            candidates.append(rootURL.appendingPathComponent(path))
            if !path.contains("/") {
                candidates.append(rootURL.appendingPathComponent("assets/\(path)"))
            }
        }
        return candidates
    }

    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "svg", "pdf"]

    private func filenameLookup() -> [String: URL] {
        if let filenameIndex { return filenameIndex }
        var map: [String: URL] = [:]
        if let rootURL,
           let enumerator = FileManager.default.enumerator(
               at: rootURL,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator
            where Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                map[url.lastPathComponent.lowercased()] = url
            }
        }
        filenameIndex = map
        return map
    }

    private func fetchRemote(_ urlString: String) {
        guard !pendingRemote.contains(urlString),
              !failedRemote.contains(urlString),
              let url = URL(string: urlString) else { return }
        pendingRemote.insert(urlString)
        Task { [weak self] in
            let loaded: NSImage?
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                loaded = NSImage(data: data)
            } catch {
                loaded = nil
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingRemote.remove(urlString)
                if let loaded {
                    self.store(urlString, loaded)
                    self.onRemoteImageLoaded?()
                } else {
                    self.failedRemote.insert(urlString)
                }
            }
        }
    }

    private func store(_ key: String, _ image: NSImage) {
        if cache.count > 100 { cache.removeAll() }
        cache[key] = image
    }

    public func invalidate() {
        cache.removeAll()
        failedRemote.removeAll()
        filenameIndex = nil
    }
}
