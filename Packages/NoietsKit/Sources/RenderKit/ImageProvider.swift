import AppKit

/// Loads and caches images referenced from notes.
/// - Local paths resolve against the vault root (absolute and ~ paths work
///   too); bare names fall back to the vault's assets/ folder.
/// - http(s) URLs download once in the background; the completion hook lets
///   the editor re-render the line when the image arrives.
@MainActor
public final class ImageProvider {
    public var rootURL: URL?
    /// Fired on the main actor whenever a remote image finishes downloading.
    public var onRemoteImageLoaded: (() -> Void)?

    private var cache: [String: NSImage] = [:]
    private var pendingRemote: Set<String> = []
    private var failedRemote: Set<String> = []

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

        for candidate in localCandidates(for: trimmed) {
            if let image = NSImage(contentsOf: candidate) {
                store(trimmed, image)
                return image
            }
        }
        return nil
    }

    private func localCandidates(for path: String) -> [URL] {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return [URL(fileURLWithPath: expanded)]
        }
        guard let rootURL else { return [] }
        var candidates = [rootURL.appendingPathComponent(path)]
        if !path.contains("/") {
            // Bare filename (Obsidian ![[image.png]] style): try assets/.
            candidates.append(rootURL.appendingPathComponent("assets/\(path)"))
        }
        return candidates
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
    }
}
