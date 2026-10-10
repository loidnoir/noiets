import AppKit
import RenderKit

/// Editor visual constants — SF Pro prose/headings, Libron quotes,
/// SF Armenian fallback (Montserrat when unavailable), SF Mono code,
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

    // Code-block syntax palette — Sonokai in dark mode, muted in light.
    public var codeKeyword: NSColor
    public var codeType: NSColor
    public var codeString: NSColor
    public var codeComment: NSColor
    public var codeNumber: NSColor
    public var codeProperty: NSColor

    public static func standard() -> EditorTheme {
        EditorTheme(
            baseFontSize: 15,
            maxColumnWidth: 760,
            lineSpacing: 3.5,
            paragraphSpacing: 0, // paragraph gap == wrapped-line gap, consistent rhythm
            textColor: AppColors.color(.editorText),
            mutedColor: AppColors.color(.muted),
            accentColor: AppColors.primary,
            codeColor: AppColors.color(.inlineCode),
            codeBackground: AppColors.color(.codeBackground),
            highlightBackground: AppColors.color(.highlightBackground),
            background: AppColors.color(.editorBackground),
            codeKeyword: AppColors.color(.codeKeyword),
            codeType: AppColors.color(.codeType),
            codeString: AppColors.color(.codeString),
            codeComment: AppColors.color(.codeComment),
            codeNumber: AppColors.color(.codeNumber),
            codeProperty: AppColors.color(.codeProperty)
        )
    }

    // MARK: Fonts

    public var baseFont: NSFont { AppFonts.font(ofSize: baseFontSize) }
    public var quoteFont: NSFont { AppFonts.displayFont(ofSize: baseFontSize) }
    public var monoFont: NSFont { .monospacedSystemFont(ofSize: baseFontSize - 1.5, weight: .regular) }

    public func headingFont(level: Int) -> NSFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.60
        case 2: scale = 1.35
        case 3: scale = 1.18
        default: scale = 1.05
        }
        return AppFonts.font(ofSize: (baseFontSize * scale).rounded(), weight: level <= 2 ? .bold : .semibold)
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
