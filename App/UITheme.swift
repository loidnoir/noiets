import AppKit

/// App-chrome colors (sidebar, dividers). Editor colors live in EditorKit's
/// EditorTheme. Everything is flat and opaque — no vibrancy, no materials.
@MainActor
enum UITheme {
    // Swapped palette: the sidebar is the darker plane, content the lighter.
    static let sidebarBackground = dynamic(
        light: .white,
        dark: NSColor(white: 0.115, alpha: 1)
    )
    static let sidebarSelection = dynamic(
        light: NSColor(white: 0.9, alpha: 1),
        dark: NSColor(white: 0.24, alpha: 1)
    )
    /// Selection pill while its list owns the keyboard — the pane-focus
    /// indicator (quiet accent tint, not the system blue).
    static let sidebarSelectionFocused = dynamic(
        light: NSColor(red: 0.13, green: 0.42, blue: 0.95, alpha: 0.22),
        dark: NSColor(red: 0.35, green: 0.58, blue: 1.0, alpha: 0.28)
    )
    /// Hairline separating panes and the bottom mode bar — a touch darker
    /// than the sidebar background in both appearances.
    static let paneSeparator = dynamic(
        light: NSColor(white: 0.87, alpha: 1),
        dark: NSColor(white: 0.075, alpha: 1)
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
