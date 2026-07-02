import AppKit

/// App-chrome colors (sidebar, dividers). Editor colors live in EditorKit's
/// EditorTheme. Everything is flat and opaque — no vibrancy, no materials.
@MainActor
enum UITheme {
    static let sidebarBackground = dynamic(
        light: NSColor(red: 0.965, green: 0.962, blue: 0.952, alpha: 1),
        dark: NSColor(white: 0.145, alpha: 1)
    )
    static let sidebarSelection = dynamic(
        light: NSColor(white: 0.877, alpha: 1),
        dark: NSColor(white: 0.28, alpha: 1)
    )
    static let sidebarPrimaryText = dynamic(
        light: NSColor(white: 0.22, alpha: 1),
        dark: NSColor(white: 0.85, alpha: 1)
    )
    static let sidebarSecondaryText = dynamic(
        light: NSColor(white: 0.45, alpha: 1),
        dark: NSColor(white: 0.60, alpha: 1)
    )
    static let hairline = dynamic(
        light: NSColor(white: 0.86, alpha: 1),
        dark: NSColor(white: 0.26, alpha: 1)
    )

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
