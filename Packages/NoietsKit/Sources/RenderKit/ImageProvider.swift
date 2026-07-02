import AppKit

/// Loads and caches images referenced from notes. Local paths resolve against
/// the vault root (or the note's folder); remote URLs are out of scope for v1.
@MainActor
public final class ImageProvider {
    public var rootURL: URL?
    private var cache: [String: NSImage] = [:]

    public init() {}

    public func image(forPath path: String) -> NSImage? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("http") else { return nil }
        if let cached = cache[trimmed] { return cached }

        let expanded = (trimmed as NSString).expandingTildeInPath
        var url: URL?
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let rootURL {
            url = rootURL.appendingPathComponent(
                trimmed.removingPercentEncoding ?? trimmed
            )
        }
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        if cache.count > 100 { cache.removeAll() }
        cache[trimmed] = image
        return image
    }

    public func invalidate() {
        cache.removeAll()
    }
}
