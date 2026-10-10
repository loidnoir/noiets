import AppKit
import CoreText

/// App typography: installed SF Pro/SF Armenian, bundled Libron for quotes. Apple fonts are referenced by name, never copied into the app.
public enum AppFonts {
    private struct Key: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let italic: Bool
        let libron: Bool
    }
    // TextKit fragment drawing can run off the main actor.
    private final class FontCache: @unchecked Sendable {
        let lock = NSLock()
        var fonts: [Key: NSFont] = [:]
    }
    private static let cache = FontCache()
    private static let registered: Void = {
        for file in fontFiles {
            guard let url = fontURL(file) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    private static let fontFiles = [
        "Libron-Regular.ttf", "Libron-Bold.ttf", "Libron-Italic.ttf", "Libron-BoldItalic.ttf",
        "Montserratarm-Regular.otf", "Montserratarm-Medium.otf",
        "Montserratarm-SemiBold.otf", "Montserratarm-Bold.otf",
    ]

    private static func fontURL(_ file: String) -> URL? {
        Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fonts")
    }

    /// Prefer the locally installed SF Pro, falling back to the macOS system font.
    public static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular,
                            italic: Bool = false) -> NSFont {
        makeFont(ofSize: size, weight: weight, italic: italic, libron: false)
    }

    /// Libron is reserved for Markdown blockquotes.
    public static func displayFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular,
                                   italic: Bool = false) -> NSFont {
        makeFont(ofSize: size, weight: weight, italic: italic, libron: true)
    }

    private static func makeFont(ofSize size: CGFloat, weight: NSFont.Weight,
                                 italic: Bool, libron: Bool) -> NSFont {
        _ = registered
        let key = Key(size: size, weight: weight.rawValue, italic: italic, libron: libron)
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let cached = cache.fonts[key] { return cached }
        // Libron ships regular/bold, not medium/semibold. Preserve hierarchy
        // with bold for semibold and above; SF has the full weight range.
        let bold = weight.rawValue >= NSFont.Weight.semibold.rawValue
        let style = bold ? (italic ? "BoldItalic" : "Bold") : (italic ? "Italic" : "Regular")
        let sfName = "SFPro-\(sfStyle(weight))\(italic ? "Italic" : "")"
        let installedSF = NSFont(name: sfName, size: size)
        var base = installedSF ?? NSFont.systemFont(ofSize: size, weight: weight)
        if libron {
            base = NSFont(name: "Libron-\(style)", size: size) ?? base
        } else if installedSF == nil, italic {
            // Named SF italic faces already carry the requested weight.
            base = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(
                base.fontDescriptor.symbolicTraits.union(.italic)), size: size) ?? base
        }
        let result = withArmenianFallback(base, weight: weight)
        cache.fonts[key] = result
        return result
    }

    private static func sfStyle(_ weight: NSFont.Weight) -> String {
        switch weight.rawValue {
        case ..<NSFont.Weight.thin.rawValue: return "Ultralight"
        case ..<NSFont.Weight.light.rawValue: return "Thin"
        case ..<NSFont.Weight.regular.rawValue: return "Light"
        case ..<NSFont.Weight.medium.rawValue: return "Regular"
        case ..<NSFont.Weight.semibold.rawValue: return "Medium"
        case ..<NSFont.Weight.bold.rawValue: return "Semibold"
        case ..<NSFont.Weight.heavy.rawValue: return "Bold"
        case ..<NSFont.Weight.black.rawValue: return "Heavy"
        default: return "Black"
        }
    }

    private static func withArmenianFallback(_ base: NSFont, weight: NSFont.Weight) -> NSFont {
        let armenianStyle: String
        if weight.rawValue >= NSFont.Weight.bold.rawValue { armenianStyle = "Bold" }
        else if weight.rawValue >= NSFont.Weight.semibold.rawValue { armenianStyle = "SemiBold" }
        else if weight.rawValue >= NSFont.Weight.medium.rawValue { armenianStyle = "Medium" }
        else { armenianStyle = "Regular" }
        let sfName = "SFArmenian-\(sfStyle(weight))"
        let name = NSFont(name: sfName, size: base.pointSize) != nil ? sfName : "Montserratarm-\(armenianStyle)"
        let armenian = NSFontDescriptor(fontAttributes: [
            .name: name,
            NSFontDescriptor.AttributeName(kCTFontOpticalSizeAttribute as String): base.pointSize,
            .characterSet: CharacterSet(charactersIn: "\u{0530}"..."\u{058F}")
                .union(CharacterSet(charactersIn: "\u{FB13}"..."\u{FB17}")),
        ])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [armenian]])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    /// Rebuild the fallback along with the primary font when markdown adds
    /// emphasis. Monospaced code keeps its own family and trait conversion.
    public static func addingTraits(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let merged = font.fontDescriptor.symbolicTraits.union(traits)
        if font.familyName == "Libron" {
            return displayFont(ofSize: font.pointSize, weight: merged.contains(.bold) ? .bold : .regular,
                               italic: merged.contains(.italic))
        }
        let converted = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(merged), size: font.pointSize) ?? font
        guard !merged.contains(.monoSpace) else { return converted }
        let fontTraits = converted.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = (fontTraits?[.weight] as? NSNumber)?.doubleValue ?? NSFont.Weight.regular.rawValue
        return withArmenianFallback(converted, weight: NSFont.Weight(rawValue: weight))
    }

    /// WebKit references installed Apple fonts with local(), never embedding
    /// them. The bundled OFL Armenian font remains the fallback on other Macs.
    public static let webCSS: String = {
        var rules: [String] = []
        for (weight, face) in [("400", "Regular"), ("500", "Medium"), ("600", "Semibold"), ("700", "Bold")] {
            for (style, suffix) in [("normal", ""), ("italic", "Italic")] {
                rules.append("@font-face { font-family: 'Noiets SF Pro'; font-weight: \(weight); font-style: \(style); src: local('SFPro-\(face)\(suffix)'); }")
            }
        }
        for (file, family, weight, style, range) in [
            ("Montserratarm-Regular.otf", "Noiets Armenian", "400", "normal", "unicode-range: U+0530-058F, U+FB13-FB17;"),
            ("Montserratarm-Medium.otf", "Noiets Armenian", "500", "normal", "unicode-range: U+0530-058F, U+FB13-FB17;"),
            ("Montserratarm-SemiBold.otf", "Noiets Armenian", "600", "normal", "unicode-range: U+0530-058F, U+FB13-FB17;"),
            ("Montserratarm-Bold.otf", "Noiets Armenian", "700", "normal", "unicode-range: U+0530-058F, U+FB13-FB17;"),
        ] {
            guard let url = fontURL(file), let data = try? Data(contentsOf: url) else { continue }
            let mime = file.hasSuffix("otf") ? "font/otf" : "font/ttf"
            let sfFace: String
            switch weight {
            case "500": sfFace = "Medium"
            case "600": sfFace = "Semibold"
            case "700": sfFace = "Bold"
            default: sfFace = "Regular"
            }
            rules.append("@font-face { font-family: '\(family)'; font-weight: \(weight); font-style: \(style); src: local('SFArmenian-\(sfFace)'), url(data:\(mime);base64,\(data.base64EncodedString())); \(range) }")
        }
        return rules.joined(separator: "\n")
    }()
}
