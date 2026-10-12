import AppKit
import MarkdownKit
import RenderKit

/// Print-friendly HTML for the existing paginated WebKit PDF exporter.
/// Uses editor metrics, but never the window's dark/translucent backdrop.
@MainActor
public enum EditorPrintDocument {
    public static func html(from markdown: String, title: String, noteURL: URL,
                            vaultRoot: URL, theme: EditorTheme = .standard()) async -> String {
        let provider = ImageProvider()
        provider.rootURL = vaultRoot
        provider.noteFolderURL = noteURL.deletingLastPathComponent()
        var assets: [String: HTMLExport.ImageSource] = [:]
        for path in Set(HTMLExport.images(in: markdown).map(\.path)) {
            let image: NSImage?
            if let url = URL(string: path), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                do {
                    let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
                    image = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
                        ? NSImage(data: data) : nil
                } catch { image = nil }
            } else if let url = provider.resolveFileURL(forPath: path) {
                image = NSImage(contentsOf: url)
            } else { image = nil }
            guard let image, image.size.width > 0, image.size.height > 0,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            // Same no-upscaling, aspect-preserving bounds as ImageLineFragment.
            let scale = min(1, min(560 / image.size.width, 420 / image.size.height))
            assets[path] = HTMLExport.ImageSource(url: "data:image/png;base64,\(png.base64EncodedString())",
                                                  width: image.size.width * scale, height: image.size.height * scale)
        }
        return HTMLExport.html(from: markdown, title: title, additionalCSS: styleSheet(theme: theme),
                               preserveBlankLines: true, imageSource: { assets[$0] })
    }

    public static func styleSheet(theme: EditorTheme = .standard()) -> String {
        func lineHeight(_ font: NSFont) -> CGFloat { font.ascender - font.descender + font.leading + theme.lineSpacing }
        let inset = IncrementalHighlighter.listTextInset(theme)
        let headings = (1...6).map { level in
            let font = theme.headingFont(level: level)
            let style = theme.headingParagraphStyle(level: level)
            return "h\(level) { font-size: \(font.pointSize)px; font-weight: \(level <= 2 ? 700 : 600); line-height: \(lineHeight(font))px; margin: \(style.paragraphSpacingBefore)px 0 \(style.paragraphSpacing)px; }"
        }.joined(separator: "\n")
        return """
        \(AppFonts.webCSS)
        \(AppFonts.quoteWebCSS)
        :root { color-scheme: light; }
        html, body { background: white; color: #292929; }
        body { font-family: 'Noiets Armenian', 'Noiets SF Pro', -apple-system, system-ui, sans-serif;
          font-size: \(theme.baseFontSize)px; line-height: \(lineHeight(theme.baseFont))px;
          max-width: \(theme.maxColumnWidth)px; margin: 0 auto; padding: 0; font-optical-sizing: auto; }
        p { margin: 0; }
        .blank-line { height: \(lineHeight(theme.baseFont))px; }
        \(headings)
        h1, h2, h3, h4, h5, h6 { break-after: avoid; }
        ul, ol { margin: 0; padding-left: \(inset)px; }
        li { margin: 0; padding: 0; }
        li::marker, a { color: #14a4c4; }
        li.task { list-style: none; position: relative; }
        li.task input { position: absolute; left: -\(inset)px; top: 3px; margin: 0; accent-color: #14a4c4; }
        li.completed { color: #666; text-decoration: line-through; }
        blockquote { font-family: 'Noiets Armenian', 'Noiets Libron', 'Noiets SF Pro', -apple-system, sans-serif;
          color: #666; border-left: 2px solid #bbb; margin: 0;
          padding-left: \(max(0, inset - 2))px; line-height: \(lineHeight(theme.quoteFont))px; }
        code, pre { font-family: ui-monospace, monospace; font-size: \(theme.monoFont.pointSize)px; }
        code { color: #666; background: none; padding: 0; }
        pre { background: #efefef; color: #292929; padding: 12px 10px; margin: 8px 0;
          line-height: \(lineHeight(theme.monoFont))px; white-space: pre-wrap; overflow-wrap: anywhere; }
        pre code { color: inherit; }
        table { width: 100%; }
        th, td { padding: 4px 10px; border-color: #ddd; }
        img { max-width: 100%; height: auto; max-height: 420px; object-fit: contain; margin: 8px 0; vertical-align: middle;
          break-inside: avoid; page-break-inside: avoid; }
        p:has(> img:only-child) { line-height: 0; break-inside: avoid; }
        .missing-image { display: inline-block; color: #666; border: 1px dashed #bbb; padding: 8px; }
        @media print { html, body { background: white; color: #292929; } }
        """
    }
}
