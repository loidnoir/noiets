import AppKit

/// Editor visual constants — Things-3 calm: SF for prose, SF Mono for code,
/// generous spacing, muted markers, no chrome.
@MainActor
public struct EditorTheme {
    public var baseFontSize: CGFloat
    public var maxColumnWidth: CGFloat
    public var lineSpacing: CGFloat
    public var paragraphSpacing: CGFloat

    public var textColor: NSColor
    public var mutedColor: NSColor      // syntax markers, metadata
    public var accentColor: NSColor     // links, wiki-links, caret
    public var codeColor: NSColor
    public var codeBackground: NSColor
    public var background: NSColor

    public static func standard() -> EditorTheme {
        EditorTheme(
            baseFontSize: 15,
            maxColumnWidth: 760,
            lineSpacing: 3.5,
            paragraphSpacing: 7,
            textColor: dynamic(light: NSColor(white: 0.16, alpha: 1), dark: NSColor(white: 0.86, alpha: 1)),
            mutedColor: dynamic(light: NSColor(white: 0.68, alpha: 1), dark: NSColor(white: 0.45, alpha: 1)),
            accentColor: dynamic(light: NSColor(red: 0.13, green: 0.42, blue: 0.95, alpha: 1),
                                 dark: NSColor(red: 0.35, green: 0.58, blue: 1.0, alpha: 1)),
            codeColor: dynamic(light: NSColor(red: 0.72, green: 0.25, blue: 0.35, alpha: 1),
                               dark: NSColor(red: 0.90, green: 0.51, blue: 0.55, alpha: 1)),
            codeBackground: dynamic(light: NSColor(white: 0.955, alpha: 1), dark: NSColor(white: 0.16, alpha: 1)),
            background: dynamic(light: .white, dark: NSColor(white: 0.115, alpha: 1))
        )
    }

    // MARK: Fonts

    public var baseFont: NSFont { .systemFont(ofSize: baseFontSize) }
    public var monoFont: NSFont { .monospacedSystemFont(ofSize: baseFontSize - 1.5, weight: .regular) }

    public func headingFont(level: Int) -> NSFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.60
        case 2: scale = 1.35
        case 3: scale = 1.18
        default: scale = 1.05
        }
        return .systemFont(ofSize: (baseFontSize * scale).rounded(), weight: level <= 2 ? .bold : .semibold)
    }

    // MARK: Base attributes

    public var defaultParagraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        p.paragraphSpacing = paragraphSpacing
        return p
    }

    public func typingAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: textColor,
            .paragraphStyle: defaultParagraphStyle,
        ]
    }

    // MARK: Helpers

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
