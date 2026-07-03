import AppKit

/// Custom SVG icons bundled with the app (App/Resources/Icons). Loaded as
/// template images so they tint with the surrounding text color.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func folder(size: CGFloat) -> NSImage? { named("Folder", size: size) }
    static func document(size: CGFloat) -> NSImage? { named("Document", size: size) }
    static func trash(size: CGFloat) -> NSImage? { named("Trash", size: size) }

    private static func named(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)-\(size)"
        if let cached = cache[key] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: size, height: size)
        cache[key] = image
        return image
    }
}
