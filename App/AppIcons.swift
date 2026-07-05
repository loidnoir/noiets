import AppKit

/// Custom SVG icons bundled with the app (App/Resources/Icons). Most are
/// template images that tint with surrounding text.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func folder(size: CGFloat) -> NSImage? { named("Folder", size: size) }
    static func document(size: CGFloat) -> NSImage? { named("Document", size: size) }
    static func trash(size: CGFloat) -> NSImage? { named("Trash", size: size) }
    /// `template: false` keeps the SVG's own colors instead of tinting.
    static func view(size: CGFloat, template: Bool = true) -> NSImage? {
        named("View", size: size, template: template)
    }
    static func docs(size: CGFloat) -> NSImage? { named("Docs", size: size) }
    static func finder(size: CGFloat) -> NSImage? {
        named("Finder", size: size, template: false,
              tint: (key: "information", color: UITheme.informationColor))
    }
    static func save(size: CGFloat) -> NSImage? { named("Save", size: size) }
    static func sidebar(size: CGFloat) -> NSImage? { named("Sidebar", size: size) }
    static func addDocument(size: CGFloat) -> NSImage? { named("AddDocument", size: size) }
    static func addFolder(size: CGFloat) -> NSImage? { named("AddFolder", size: size) }

    private static func named(
        _ name: String,
        size: CGFloat,
        template: Bool = true,
        tint: (key: String, color: NSColor)? = nil
    ) -> NSImage? {
        let key = "\(name)-\(size)-\(template)-\(tint?.key ?? "none")"
        if let cached = cache[key] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: size, height: size)
        let output: NSImage
        if let tint {
            output = tinted(image, color: tint.color, size: size)
        } else {
            image.isTemplate = template
            output = image
        }
        cache[key] = output
        return output
    }

    private static func tinted(_ image: NSImage, color: NSColor, size: CGFloat) -> NSImage {
        let iconSize = NSSize(width: size, height: size)
        let rect = NSRect(origin: .zero, size: iconSize)
        let tinted = NSImage(size: iconSize)
        tinted.lockFocus()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }
}
