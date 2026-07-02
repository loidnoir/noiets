import AppKit
import SwiftMath

/// Native LaTeX rendering via SwiftMath (CoreText, no WebView). Rendered
/// images are drawn inside custom layout fragments.
@MainActor
public enum MathRenderer {
    private static var cache: [String: NSImage] = [:]

    public static func image(latex: String, fontSize: CGFloat, textColor: NSColor) -> NSImage? {
        let key = "\(fontSize)|\(textColor.description)|\(latex)"
        if let cached = cache[key] { return cached }
        let renderer = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: textColor,
            labelMode: .display
        )
        let (error, image) = renderer.asImage()
        guard error == nil, let image else { return nil }
        if cache.count > 200 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
