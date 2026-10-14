import AppKit

/// Sam's palette: distinct base hues first, followed by dark and light variants.
public enum TagPalette {
    public static let baseHex = [
        "de2618", "d14917", "d9c50f", "b0c41a", "8dd10f", "0fd13c", "1ad986", "0dd6bb",
        "0dc1e0", "0d8ce0", "1857d6", "6019e3", "8814db", "d52ef2", "e629b6", "e82771"
    ]
    public static let count = baseHex.count * 3

    public static func color(at index: Int) -> NSColor {
        let slot = ((index % count) + count) % count
        let rgb = UInt32(baseHex[slot % baseHex.count], radix: 16)!
        var components = [CGFloat((rgb >> 16) & 255), CGFloat((rgb >> 8) & 255), CGFloat(rgb & 255)].map { $0 / 255 }
        switch slot / baseHex.count {
        case 1: components = components.map { $0 * 0.72 }
        case 2: components = components.map { $0 + (1 - $0) * 0.25 }
        default: break
        }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
    }
}
