import AppKit

/// Stable semantic color objects. Debug overrides are in-memory only; dynamic
/// providers keep already-created themes/views live without replacing editors.
public enum AppColors {
    public enum Appearance: String, CaseIterable, Sendable {
        case light, dark

        public init(_ appearance: NSAppearance) {
            self = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
    }

    public enum Role: String, CaseIterable, Sendable {
        case primary
        case editorBackground, editorText, muted, inlineCode, codeBackground, highlightBackground
        case codeKeyword, codeType, codeString, codeComment, codeNumber, codeProperty
        case sidebarBackground, sidebarText, sidebarSecondaryText, sidebarSelection, sidebarFocusedSelection
        case paneSeparator, hairline, modeInsert, modeVisual

        public var label: String {
            switch self {
            case .primary: return "Primary / links / caret"
            case .editorBackground: return "Content background"
            case .editorText: return "Body text"
            case .muted: return "Quotes / muted syntax"
            case .inlineCode: return "Inline code / math"
            case .codeBackground: return "Code background"
            case .highlightBackground: return "Text highlight"
            case .codeKeyword: return "Code keywords"
            case .codeType: return "Code types"
            case .codeString: return "Code strings"
            case .codeComment: return "Code comments"
            case .codeNumber: return "Code numbers"
            case .codeProperty: return "Code properties"
            case .sidebarBackground: return "Sidebar background"
            case .sidebarText: return "Sidebar text"
            case .sidebarSecondaryText: return "Sidebar secondary text"
            case .sidebarSelection: return "Sidebar selection"
            case .sidebarFocusedSelection: return "Focused selection"
            case .paneSeparator: return "Pane separators"
            case .hairline: return "Hairlines"
            case .modeInsert: return "Insert mode"
            case .modeVisual: return "Visual mode"
            }
        }

        fileprivate func defaultColor(in appearance: Appearance) -> NSColor {
            let dark = appearance == .dark
            switch self {
            case .primary: return NSColor(srgbRed: 95.0 / 255, green: 170.0 / 255, blue: 236.0 / 255, alpha: 1)
            case .editorBackground: return dark ? NSColor(white: 0.145, alpha: 1) : rgb(0.972, 0.970, 0.962)
            case .editorText: return NSColor(white: dark ? 0.86 : 0.16, alpha: 1)
            case .muted: return NSColor(white: dark ? 0.45 : 0.68, alpha: 1)
            case .inlineCode: return dark ? rgb(0.90, 0.51, 0.55) : rgb(0.72, 0.25, 0.35)
            case .codeBackground: return dark ? NSColor(srgbRed: 29.0 / 255, green: 29.0 / 255, blue: 29.0 / 255, alpha: 1) : NSColor(white: 0.935, alpha: 1)
            case .highlightBackground: return dark ? rgb(0.42, 0.37, 0.12) : rgb(1.0, 0.95, 0.60)
            case .codeKeyword: return dark ? rgb(0.988, 0.365, 0.486) : rgb(0.61, 0.15, 0.55)
            case .codeType: return dark ? rgb(0.463, 0.800, 0.878) : rgb(0.16, 0.42, 0.62)
            case .codeString: return dark ? rgb(0.906, 0.776, 0.392) : rgb(0.75, 0.28, 0.16)
            case .codeComment: return dark ? rgb(0.498, 0.518, 0.565) : NSColor(white: 0.58, alpha: 1)
            case .codeNumber: return dark ? rgb(0.702, 0.616, 0.953) : rgb(0.15, 0.45, 0.40)
            case .codeProperty: return dark ? rgb(0.620, 0.816, 0.447) : rgb(0.16, 0.42, 0.62)
            case .sidebarBackground: return dark ? NSColor(white: 0.115, alpha: 1) : .white
            case .sidebarText: return NSColor(white: dark ? 0.85 : 0.22, alpha: 1)
            case .sidebarSecondaryText: return NSColor(white: dark ? 0.60 : 0.45, alpha: 1)
            case .sidebarSelection: return NSColor(white: dark ? 0.24 : 0.9, alpha: 1)
            case .sidebarFocusedSelection: return AppColors.resolved(.primary, in: appearance).withAlphaComponent(dark ? 0.28 : 0.22)
            case .paneSeparator: return NSColor(white: dark ? 0.075 : 0.87, alpha: 1)
            case .hairline: return NSColor(white: dark ? 0.26 : 0.86, alpha: 1)
            case .modeInsert: return rgb(207.0 / 255, 80.0 / 255, 58.0 / 255)
            case .modeVisual: return rgb(141.0 / 255, 83.0 / 255, 212.0 / 255)
            }
        }

        private func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
            NSColor(red: red, green: green, blue: blue, alpha: 1)
        }
    }

    // TextKit fragment drawing can resolve colors off the main actor. All
    // mutable storage is locked; cached NSColors and override values are immutable.
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var colors: [Role: NSColor] = [:]
        var overrides: [Appearance: [Role: NSColor]] = [:]
    }
    private static let store = Store()
    public static let didChange = Notification.Name("NoietsThemeColorsDidChange")
    public static var primary: NSColor { color(.primary) }

    public static func color(_ role: Role) -> NSColor {
        store.lock.lock()
        let cached = store.colors[role]
        store.lock.unlock()
        if let cached { return cached }
        // Construct outside the lock: AppKit may evaluate a provider here.
        let created = NSColor(name: NSColor.Name("Noiets.\(role.rawValue)")) { appearance in
            resolved(role, in: Appearance(appearance))
        }
        store.lock.lock()
        defer { store.lock.unlock() }
        if let cached = store.colors[role] { return cached }
        store.colors[role] = created
        return created
    }

    public static func resolved(_ role: Role, in appearance: Appearance) -> NSColor {
        store.lock.lock()
        let override = store.enabled ? store.overrides[appearance]?[role] : nil
        store.lock.unlock()
        return override ?? role.defaultColor(in: appearance)
    }

    @MainActor public static func enableDebugMode() {
        store.lock.lock()
        store.enabled = true
        store.lock.unlock()
    }

    @MainActor public static func disableDebugMode() {
        store.lock.lock()
        store.enabled = false
        store.overrides.removeAll()
        store.lock.unlock()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    @MainActor @discardableResult
    public static func setOverride(_ color: NSColor, for role: Role, in appearance: Appearance) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        store.lock.lock()
        guard store.enabled else { store.lock.unlock(); return false }
        store.overrides[appearance, default: [:]][role] = rgb
        store.lock.unlock()
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    @MainActor public static func resetOverrides() {
        store.lock.lock()
        store.overrides.removeAll()
        store.lock.unlock()
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Strict #RRGGBB / #RRGGBBAA; incomplete input never changes the theme.
    public static func parseHex(_ input: String) -> NSColor? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard [6, 8].contains(digits.count), digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }), let number = UInt32(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? (number << 8) | 0xff : number
        return NSColor(srgbRed: CGFloat((rgba >> 24) & 255) / 255,
                       green: CGFloat((rgba >> 16) & 255) / 255,
                       blue: CGFloat((rgba >> 8) & 255) / 255,
                       alpha: CGFloat(rgba & 255) / 255)
    }

    public static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        let red = Int((min(max(rgb.redComponent, 0), 1) * 255).rounded())
        let green = Int((min(max(rgb.greenComponent, 0), 1) * 255).rounded())
        let blue = Int((min(max(rgb.blueComponent, 0), 1) * 255).rounded())
        let alpha = Int((min(max(rgb.alphaComponent, 0), 1) * 255).rounded())
        return alpha == 255 ? String(format: "#%02X%02X%02X", red, green, blue)
            : String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    @MainActor public static func paletteJSON() -> String {
        var palette: [String: [String: String]] = [:]
        for appearance in Appearance.allCases {
            palette[appearance.rawValue] = Dictionary(uniqueKeysWithValues: Role.allCases.map {
                ($0.rawValue, hex(resolved($0, in: appearance)))
            })
        }
        guard let data = try? JSONSerialization.data(withJSONObject: palette, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
