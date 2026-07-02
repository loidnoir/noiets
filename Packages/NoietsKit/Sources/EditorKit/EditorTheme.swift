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
    public var highlightBackground: NSColor
    public var background: NSColor

    // Code-block syntax palette (muted, Things-calm).
    public var codeKeyword: NSColor
    public var codeType: NSColor
    public var codeString: NSColor
    public var codeComment: NSColor
    public var codeNumber: NSColor

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
            highlightBackground: dynamic(light: NSColor(red: 1.0, green: 0.95, blue: 0.60, alpha: 1),
                                         dark: NSColor(red: 0.42, green: 0.37, blue: 0.12, alpha: 1)),
            background: dynamic(light: .white, dark: NSColor(white: 0.115, alpha: 1)),
            codeKeyword: dynamic(light: NSColor(red: 0.61, green: 0.15, blue: 0.55, alpha: 1),
                                 dark: NSColor(red: 0.81, green: 0.51, blue: 0.87, alpha: 1)),
            codeType: dynamic(light: NSColor(red: 0.16, green: 0.42, blue: 0.62, alpha: 1),
                              dark: NSColor(red: 0.45, green: 0.72, blue: 0.90, alpha: 1)),
            codeString: dynamic(light: NSColor(red: 0.75, green: 0.28, blue: 0.16, alpha: 1),
                                dark: NSColor(red: 0.90, green: 0.57, blue: 0.44, alpha: 1)),
            codeComment: dynamic(light: NSColor(white: 0.58, alpha: 1),
                                 dark: NSColor(white: 0.42, alpha: 1)),
            codeNumber: dynamic(light: NSColor(red: 0.15, green: 0.45, blue: 0.40, alpha: 1),
                                dark: NSColor(red: 0.48, green: 0.78, blue: 0.68, alpha: 1))
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

    public func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        p.paragraphSpacing = 8
        p.paragraphSpacingBefore = level == 1 ? 18 : (level == 2 ? 14 : 10)
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
